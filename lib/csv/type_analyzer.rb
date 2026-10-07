# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

class CSV
  #
  # CSV::TypeAnalyzer performs a <b>read-only</b> column type analysis over a
  # limited sample of records. It reports, for each column position, which
  # candidate converters are still viable, why the others were excluded, and
  # whether the column may be null. It is meant to help callers decide on an
  # import schema before committing to converters.
  #
  # The analyzer never modifies the data and never decides a column type from
  # a single record: every sampled record is checked, a later record can
  # overrule a candidate that earlier records allowed, and the exclusion
  # reason is kept in the report.
  #
  # Candidate converters:
  #
  # [:integer]  Integer values, subject to the +leading_zeros+ and
  #             +large_integer+ policies.
  # [:decimal]  Exact decimal values (BigDecimal-compatible). Integer values
  #             also match, so an all-integer column keeps both candidates.
  # [:date]     ISO 8601 dates (<tt>YYYY-MM-DD</tt>).
  # [:time]     ISO 8601 date-times that carry an explicit timezone offset
  #             or +Z+.
  # [:string]   Always viable; the fallback candidate.
  #
  # Example:
  #
  #   analyzer = CSV::TypeAnalyzer.new(sample_size: 500, headers: true)
  #   report = analyzer.analyze(File.open("data.csv", "r"))
  #   report.eof?          # => false (only a sample was read)
  #   report.columns[0].candidates # => [:integer, :decimal, :string]
  #   report.each { |row| ... }    # replays the sample, then keeps reading
  #
  class TypeAnalyzer
    # All candidate converter names, in reporting order.
    CANDIDATES = %i[integer decimal date time string].freeze

    # Signed 64-bit range, used by the +large_integer+ policy. It matches the
    # range of a typical database +bigint+ column.
    INTEGER_RANGE = (-(2**63)..(2**63 - 1)).freeze

    INTEGER_PATTERN = /\A[+-]?\d+\z/.freeze
    DECIMAL_PATTERN = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/.freeze
    ISO_DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/.freeze
    TZ_TIME_PATTERN =
      /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?\s*
        (?:Z|[+-]\d{2}:?\d{2})\z/x.freeze
    LEADING_ZEROS_PATTERN = /\A[+-]?0\d/.freeze

    # Options reserved by the analyzer itself; anything else is passed
    # through to CSV.new.
    ANALYZER_OPTIONS = %i[
      sample_size
      max_examples
      mask_values
      headers
      leading_zeros
      large_integer
      empty_unquoted
      quoted_empty
    ].freeze

    # CSV options that would interfere with raw, read-only sampling.
    FORBIDDEN_CSV_OPTIONS = %i[
      converters
      unconverted_fields
      nil_value
      empty_value
      accept_nil
      builtin_converters_name
    ].freeze

    # Per-column analysis result. Instances are built by
    # CSV::TypeAnalyzer#analyze.
    class ColumnReport
      # Zero-based column position. Duplicate headers are analyzed per
      # position, so this is the stable identifier of the column.
      attr_reader :index
      # The header for this position, or nil when headers are not used or
      # the row had more fields than headers.
      attr_reader :header
      # Exclusion details, keyed by converter name:
      #   {date: {reason: :not_an_iso_date, count: 3, examples: [...]}}
      # Each example is a Hash with :record (1-based sampled record number),
      # :line (input line number), :column and :value (possibly masked).
      attr_reader :exclusions

      def initialize(index, header) # :nodoc:
        @index = index
        @header = header
        @nullable = false
        @exclusions = {}
      end

      # Whether a null value was observed in this column (see the
      # +empty_unquoted+ and +quoted_empty+ policies).
      def nullable?
        @nullable
      end

      # Names of the converters that are still viable for this column,
      # in CANDIDATES order. Always includes +:string+.
      def candidates
        CANDIDATES.reject {|name| @exclusions.key?(name)}
      end

      # Whether +converter+ has been ruled out for this column.
      def excluded?(converter)
        @exclusions.key?(converter)
      end

      def to_h
        {
          index: @index,
          header: @header,
          nullable: nullable?,
          candidates: candidates,
          exclusions: @exclusions.transform_values do |exclusion|
            {
              reason: exclusion[:reason],
              count: exclusion[:count],
              examples: exclusion[:examples].map(&:dup),
            }
          end,
        }
      end

      # @private

      def mark_nullable
        @nullable = true
      end

      # @private
      # Records +reason+ for +converter+. The first reason observed is kept;
      # later records may add examples (up to +max_examples+) and always
      # increment the count.
      def exclude(converter, reason, example, max_examples)
        entry = (@exclusions[converter] ||= {
          reason: reason,
          count: 0,
          examples: [],
        })
        entry[:count] += 1
        entry[:examples] << example if entry[:examples].size < max_examples
      end
    end

    # The result of CSV::TypeAnalyzer#analyze.
    class Report
      include Enumerable

      # Array of CSV::TypeAnalyzer::ColumnReport, one per column position.
      attr_reader :columns
      # Number of data records that were sampled.
      attr_reader :sampled_rows

      def initialize(columns, sampled_rows, eof, sampled, csv) # :nodoc:
        @columns = columns
        @sampled_rows = sampled_rows
        @eof = eof
        @sampled = sampled
        @csv = csv
      end

      # Whether sampling actually consumed the whole input. False means the
      # sample limit was hit and more records may exist.
      def eof?
        @eof
      end

      # Yields every record of the input without requiring it to be
      # traversable twice: first the buffered sample records (including any
      # record that overruled a type candidate), then the remaining records
      # read from the underlying CSV object.
      def each
        return to_enum(__method__) unless block_given?
        @sampled.each {|row| yield row}
        while (row = @csv.shift)
          yield row
        end
        self
      end

      def to_h
        {
          sampled_rows: @sampled_rows,
          eof: eof?,
          columns: @columns.map(&:to_h),
        }
      end
    end

    # :call-seq:
    #   CSV::TypeAnalyzer.new(**options)
    #
    # Options:
    #
    # [sample_size]   Maximum number of data records to sample.
    #                 Default: 1000.
    # [max_examples]  Maximum number of example positions kept per column per
    #                 excluded converter. Default: 3.
    # [mask_values]   When true, example values are replaced by a placeholder
    #                 that only reveals the value length. A callable may be
    #                 given to mask values itself. Default: false.
    # [headers]       Passed to CSV.new. Duplicate headers are analyzed per
    #                 column position. Default: false.
    # [leading_zeros] Policy for numeric-looking values with leading zeros
    #                 (e.g. <tt>"007"</tt>):
    #                 [:string (default)] exclude :integer and :decimal, since
    #                                     converting would drop the zeros.
    #                 [:convert]          allow numeric conversion.
    # [large_integer] Policy for integers outside the signed 64-bit range:
    #                 [:decimal (default)] exclude :integer, keep :decimal.
    #                 [:integer]           allow arbitrary-size integers.
    #                 [:string]            exclude :integer and :decimal.
    # [empty_unquoted] Policy for empty unquoted fields:
    #                 [:null (default)]   treat as null (marks the column
    #                                     nullable, skips type checks).
    #                 [:empty_string]     treat as an empty string value.
    # [quoted_empty]  Policy for quoted empty fields (<tt>""</tt>):
    #                 [:empty_string (default)] treat as an empty string
    #                                     value (excludes non-string
    #                                     converters).
    #                 [:null]             treat as null.
    #
    # Any other options are passed through to CSV.new (e.g. +:col_sep+),
    # except converter-related options, which are forbidden because sampling
    # must observe raw values.
    def initialize(**options)
      unknown = options.keys - ANALYZER_OPTIONS - CSV::DEFAULT_OPTIONS.keys
      raise ArgumentError, "unknown options: #{unknown.join(', ')}" unless unknown.empty?
      forbidden = options.keys & FORBIDDEN_CSV_OPTIONS
      unless forbidden.empty?
        raise ArgumentError,
              "options not allowed for read-only analysis: #{forbidden.join(', ')}"
      end

      @sample_size = options.fetch(:sample_size, 1000)
      @max_examples = options.fetch(:max_examples, 3)
      @mask_values = options.fetch(:mask_values, false)
      @headers = options.fetch(:headers, false)
      @leading_zeros = check_policy(options.fetch(:leading_zeros, :string),
                                    %i[string convert], :leading_zeros)
      @large_integer = check_policy(options.fetch(:large_integer, :decimal),
                                    %i[integer decimal string], :large_integer)
      @empty_unquoted = check_policy(options.fetch(:empty_unquoted, :null),
                                     %i[null empty_string], :empty_unquoted)
      @quoted_empty = check_policy(options.fetch(:quoted_empty, :empty_string),
                                   %i[null empty_string], :quoted_empty)
      @csv_options = options.reject {|key, _| ANALYZER_OPTIONS.include?(key)}
    end

    # :call-seq:
    #   analyze(input) -> CSV::TypeAnalyzer::Report
    #
    # Samples up to +sample_size+ records from +input+ (anything accepted by
    # CSV.new) and returns a CSV::TypeAnalyzer::Report. The input is read
    # once, forward-only; use Report#each to replay the sampled records and
    # continue reading the rest.
    def analyze(input)
      fields = nil
      probe = lambda do |field, field_info|
        fields << [field, field_info]
        field
      end
      csv = CSV.new(input, **@csv_options,
                    headers: @headers, converters: [probe])

      columns = []
      sampled = []
      sampled_rows = 0
      eof = false
      while sampled_rows < @sample_size
        fields = []
        row = csv.shift
        if row.nil?
          eof = true
          break
        end
        sampled_rows += 1
        sampled << row
        analyze_record(fields, columns, sampled_rows)
      end
      Report.new(columns, sampled_rows, eof, sampled, csv)
    end

    private

    def check_policy(value, allowed, name)
      return value if allowed.include?(value)
      raise ArgumentError,
            "#{name} must be one of #{allowed.map(&:inspect).join(', ')}: #{value.inspect}"
    end

    def analyze_record(fields, columns, record_number)
      fields.each_with_index do |(field, field_info), index|
        column = columns[index]
        if column.nil?
          column = columns[index] = ColumnReport.new(index, header_for(field_info))
          # Earlier records had no field at this position.
          column.mark_nullable if record_number > 1
        end
        analyze_field(column, field, field_info, record_number)
      end
      # Fields missing from a short or empty row count as null.
      columns.each_with_index do |column, index|
        next if column.nil? or index < fields.size
        column.mark_nullable
      end
    end

    def header_for(field_info)
      @headers ? field_info.header : nil
    end

    def analyze_field(column, field, field_info, record_number)
      if field.nil?
        if @empty_unquoted == :null
          column.mark_nullable
          return
        end
        field = ""
      elsif field.empty? and field_info.quoted? and @quoted_empty == :null
        column.mark_nullable
        return
      end

      example = {
        record: record_number,
        line: field_info.line,
        column: field_info.index,
        value: mask(field),
      }

      begin
        value = field.encode(ConverterEncoding)
      rescue EncodingError
        exclude_all_but_string(column, :invalid_encoding, example)
        return
      end

      check_integer(column, value, example)
      check_decimal(column, value, example)
      check_date(column, value, example)
      check_time(column, value, example)
    end

    def exclude_all_but_string(column, reason, example)
      (CANDIDATES - [:string]).each do |converter|
        column.exclude(converter, reason, example, @max_examples)
      end
    end

    def mask(value)
      case @mask_values
      when true
        "<masked:#{value.length}>"
      when false, nil
        value
      else
        @mask_values.call(value)
      end
    end

    def check_integer(column, value, example)
      unless value.match?(INTEGER_PATTERN)
        column.exclude(:integer, :not_an_integer, example, @max_examples)
        return
      end
      if @leading_zeros == :string and value.match?(LEADING_ZEROS_PATTERN)
        column.exclude(:integer, :leading_zeros, example, @max_examples)
        return
      end
      if @large_integer != :integer and
         !INTEGER_RANGE.cover?(Integer(value, 10))
        column.exclude(:integer, :too_large_integer, example, @max_examples)
      end
    end

    def check_decimal(column, value, example)
      unless value.match?(DECIMAL_PATTERN)
        column.exclude(:decimal, :not_a_decimal, example, @max_examples)
        return
      end
      if @leading_zeros == :string and value.match?(LEADING_ZEROS_PATTERN)
        column.exclude(:decimal, :leading_zeros, example, @max_examples)
        return
      end
      if @large_integer == :string and value.match?(INTEGER_PATTERN) and
         !INTEGER_RANGE.cover?(Integer(value, 10))
        column.exclude(:decimal, :too_large_integer, example, @max_examples)
      end
    end

    def check_date(column, value, example)
      unless value.match?(ISO_DATE_PATTERN)
        column.exclude(:date, :not_an_iso_date, example, @max_examples)
        return
      end
      begin
        Date.iso8601(value)
      rescue Date::Error
        column.exclude(:date, :invalid_iso_date, example, @max_examples)
      end
    end

    def check_time(column, value, example)
      unless value.match?(TZ_TIME_PATTERN)
        column.exclude(:time, :not_a_zoned_time, example, @max_examples)
        return
      end
      begin
        Time.iso8601(value.sub(/(?<=\d)[T ](?=\d{2}:\d{2})/, "T"))
      rescue ArgumentError
        column.exclude(:time, :invalid_zoned_time, example, @max_examples)
      end
    end
  end
end
