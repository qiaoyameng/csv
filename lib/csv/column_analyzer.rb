# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

class CSV
  # Read-only analyzer that reports the converters still possible for each
  # column after a bounded number of records. It never converts or rewrites
  # input records. A one-record lookahead is analyzed so the next record can
  # reject a prior candidate, and remains available through #continue.
  class ColumnAnalyzer
    CONVERTER_NAMES = [
      :integer,
      :bigdecimal,
      :date,
      :time_with_zone,
      :string,
    ].freeze

    INTEGER_PATTERN = /\A[+-]?\d+\z/
    DECIMAL_PATTERN = /\A[+-]?(?:\d+\.\d+|\d+)\z/
    DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
    TIME_WITH_ZONE_PATTERN =
      /\A\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}
         (?::\d{2}(?:\.\d+)?)?
         (?:Z|[+-]\d{2}:\d{2})\z/x

    Observation = Struct.new(:value, :quoted, :line, :record)
    Example = Struct.new(:record, :line, :column, :reason, :value)

    ColumnReport = Struct.new(:index, :header, :possible_converters,
                              :candidate_converters, :rejected_converters,
                              :nullable, :non_null_count,
                              :unquoted_empty_count, :quoted_empty_count,
                              :missing_count, :examples)

    Report = Struct.new(:columns, :sample_records, :analyzed_records,
                        :eof, :headers) do
      def eof?
        eof
      end
    end

    class << self
      # Analyzes +data+ and returns a Report. +sample_records+ is the number
      # requested by the caller; the analyzer may also inspect one following
      # record, reflected in +analyzed_records+, to let later data reject an
      # earlier candidate.
      def analyze(data, sample_records: nil, headers: false, **options)
        analyzer = new(data, headers: headers, **options)
        analyzer.sample(sample_records)
        analyzer.report
      end
      alias_method :call, :analyze
    end

    def initialize(data, headers: false,
                   leading_zeros: :reject,
                   oversized_integer: :bigdecimal,
                   integer_limit: 2 ** 63,
                   unquoted_empty: :null,
                   quoted_empty: :empty_string,
                   max_examples: 3,
                   redact_values: true,
                   **csv_options)
      validate_policy(:leading_zeros,
                      leading_zeros,
                      :reject, :allow, :string, :allow_decimal)
      validate_policy(:oversized_integer,
                      oversized_integer,
                      :bigdecimal, :integer, :string)
      validate_policy(:unquoted_empty, unquoted_empty, :null, :empty_string)
      validate_policy(:quoted_empty, quoted_empty, :null, :empty_string)

      @headers_option = headers
      @leading_zeros = leading_zeros
      @oversized_integer = oversized_integer
      @integer_limit = integer_limit
      @unquoted_empty = unquoted_empty
      @quoted_empty = quoted_empty
      @max_examples = max_examples
      @redact_values = redact_values

      @headers = initial_headers(headers)
      @observations = []
      @sampled_rows = []
      @pending_record = nil
      @replayed_lookahead = false
      @records_read = 0
      @sample_limit = nil
      @eof = false
      @sampled = false
      @header_read = false
      @current_metadata = []

      managed_options = [:headers, :converters, :nil_value, :empty_value]
      conflicts = managed_options.select {|key| csv_options.key?(key)}
      unless conflicts.empty?
        raise ArgumentError,
              "CSV options #{conflicts.inspect} are managed by ColumnAnalyzer"
      end

      @csv = CSV.new(data, headers: false,
                           converters: metadata_converter,
                           **csv_options)
    end

    # Reads the requested number of records. To make #report useful without
    # trusting only the first record, one additional record is analyzed when
    # available. That record is buffered for replay/continue.
    def sample(limit = nil)
      read_header
      @sample_limit = limit

      unless limit.nil? || limit.is_a?(Integer) && limit >= 0
        raise ArgumentError, "sample_records must be a non-negative Integer"
      end

      if limit.nil?
        loop do
          row, metadata = read_next
          break unless row
          observe(row, metadata)
        end
        @pending_record = nil
        @eof = true
      else
        while @records_read < limit
          row, metadata = read_next
          break unless row
          observe(row, metadata)
        end

        if @records_read >= limit
          row, metadata = read_next
          if row
            @pending_record = [row, metadata]
            observe(row, metadata)
            @eof = @csv.eof?
          else
            @pending_record = nil
            @eof = true
          end
        else
          @eof = true
        end
      end

      @sampled = true
      self
    end
    alias_method :sample!, :sample

    # Builds an immutable snapshot of the candidate/rejection analysis.
    def report
      sample unless @sampled

      column_count = [
        @headers == false ? 0 : @headers.size,
        @sampled_rows.map(&:size).max.to_i,
      ].max
      columns = Array.new(column_count) do |index|
        build_column_report(index)
      end

      Report.new(columns,
                 @sample_limit.nil? ? @records_read : @sample_limit,
                 @records_read,
                 @eof,
                 @headers == false ? nil : @headers.dup)
    end

    def eof?
      @eof
    end

    def records_read
      @records_read
    end

    def rewind
      @csv.rewind
      reset_state
      self
    end

    # Yields each analyzed record, including the one-record lookahead, without
    # consuming the underlying one-pass input. Replay is repeatable.
    def replay
      return to_enum(__method__) unless block_given?

      @sampled_rows.each do |row|
        yield(copy_row(row))
      end
      @replayed_lookahead = @pending_record ? true : false
      nil
    end
    alias_method :each_sampled, :replay

    # Continues reading records not returned by a previous replay/continue.
    # Without replay, the analyzed lookahead is yielded first; after replay it
    # is skipped so a replay followed by continue does not duplicate it.
    def each_remaining
      return to_enum(__method__) unless block_given?

      sample unless @sampled
      if @pending_record
        unless @replayed_lookahead
          row, _metadata = @pending_record
          yield(copy_row(row))
        end
        @pending_record = nil
      end

      loop do
        row, _metadata = read_next
        @eof = true if row.nil?
        break unless row
        yield(copy_row(row))
      end
    end
    alias_method :continue, :each_remaining

    private
    def validate_policy(name, value, *allowed)
      return if allowed.include?(value)

      raise ArgumentError,
            ":#{name} must be one of #{allowed.inspect}, not #{value.inspect}"
    end

    def reset_state
      @observations = []
      @sampled_rows.clear
      @pending_record = nil
      @replayed_lookahead = false
      @records_read = 0
      @sample_limit = nil
      @eof = false
      @sampled = false
      @header_read = false
      @current_metadata = []
    end

    def initial_headers(headers)
      case headers
      when false, nil
        false
      when true
        nil
      when Array
        headers.dup
      else
        raise ArgumentError, ":headers must be true, false, or an Array"
      end
    end

    def read_header
      return if @header_read

      @header_read = true
      return unless @headers_option == true

      row, = read_next
      @headers = row || []
      @eof = true if row.nil?
    end

    def read_next
      if @pending_record
        row, metadata = @pending_record
        @pending_record = nil
        return [row, metadata]
      end

      @current_metadata = []
      row = @csv.shift
      if row.nil?
        @eof = true
        @eof_reached = true
        return [nil, nil]
      end

      @eof_reached = false
      [row, @current_metadata.dup]
    end

    def observe(row, metadata)
      @records_read += 1
      @sampled_rows << row
      record_observations = []

      row.each_with_index do |value, index|
        record_observations[index] = Observation.new(
          value,
          metadata.fetch(index, false),
          @csv.lineno,
          @records_read
        )
      end
      @observations << record_observations
    end

    def build_column_report(index)
      possible = CONVERTER_NAMES.dup
      rejected = {}
      examples = {}
      counts = Hash.new(0)
      non_null_count = 0

      @records_read.times do |record_index|
        row = @sampled_rows[record_index]
        record_observations = @observations[record_index]

        if index >= row.size
          counts[:missing] += 1
          next
        end

        observation = record_observations[index]
        state, null = empty_state(observation)
        counts[state] += 1 unless state == :present
        next if null

        non_null_count += 1
        analyze_candidate(:integer, index, observation, possible, rejected, examples)
        analyze_candidate(:bigdecimal, index, observation, possible, rejected, examples)
        analyze_candidate(:date, index, observation, possible, rejected, examples)
        analyze_candidate(:time_with_zone,
                          index,
                          observation,
                          possible,
                          rejected,
                          examples)
      end

      ColumnReport.new(
        index,
        header_for(index),
        possible.dup,
        possible.dup,
        rejected,
        nullable_observed?(counts),
        non_null_count,
        counts[:unquoted_empty],
        counts[:quoted_empty],
        counts[:missing],
        examples
      )
    end

    def analyze_candidate(name, index, observation, possible, rejected, examples)
      reason = rejection_reason(name, observation)
      return if reason.nil?

      possible.delete(name)
      details = rejected[name] ||= {reason: reason, examples: []}
      add_example(details[:examples], index, observation, reason)
    end

    def rejection_reason(name, observation)
      value = observation.value
      return "not a string" unless value.is_a?(String)

      case name
      when :integer
        integer_reason(value, observation.quoted)
      when :bigdecimal
        decimal_reason(value, observation.quoted)
      when :date
        date_reason(value)
      when :time_with_zone
        time_reason(value)
      end
    end

    def integer_reason(value, _quoted)
      return "not an integer" unless INTEGER_PATTERN.match?(value)
      return "leading zero" if leading_zero?(value, :integer)

      if oversized_integer?(value)
        case @oversized_integer
        when :integer
          nil
        when :string
          "integer exceeds limit"
        else
          "integer exceeds limit"
        end
      end
    end

    def decimal_reason(value, _quoted)
      return "not an exact decimal" unless DECIMAL_PATTERN.match?(value)
      return "leading zero" if leading_zero?(value, :bigdecimal)

      if oversized_integer?(value) && @oversized_integer == :string
        return "integer exceeds limit"
      end

      begin
        BigDecimal(value)
        nil
      rescue ArgumentError
        "not an exact decimal"
      end
    end

    def date_reason(value)
      return "not an ISO date" unless DATE_PATTERN.match?(value)

      begin
        date = Date.iso8601(value)
        date.strftime("%Y-%m-%d") == value ? nil : "not an ISO date"
      rescue Date::Error
        "not an ISO date"
      end
    end

    def time_reason(value)
      return "not an ISO time with time zone" unless
        TIME_WITH_ZONE_PATTERN.match?(value)

      begin
        if value.include?(":") && value.count(":") >= 2
          time = Time.iso8601(value)
        else
          time = DateTime.iso8601(value).to_time
        end
        time.utc_offset || raise(ArgumentError)
        nil
      rescue ArgumentError, Date::Error
        "not an ISO time with time zone"
      end
    end

    def leading_zero?(value, type)
      return false if @leading_zeros == :allow
      return false if @leading_zeros == :allow_decimal && type == :bigdecimal

      digits = value.sub(/\A[+-]/, "")
      digits.start_with?("0") && digits != "0"
    end

    def oversized_integer?(value)
      return false unless INTEGER_PATTERN.match?(value)
      return false if @integer_limit.nil?

      Integer(value, 10).abs >= @integer_limit.abs
    end

    def empty_state(observation)
      value = observation.value

      return unquoted_empty_state if value.nil?

      if value.empty?
        return observation.quoted ? quoted_empty_state : unquoted_empty_state
      end

      [:present, false]
    end

    def unquoted_empty_state
      if @unquoted_empty == :null
        [:unquoted_empty, true]
      else
        [:unquoted_empty, false]
      end
    end

    def quoted_empty_state
      if @quoted_empty == :null
        [:quoted_empty, true]
      else
        [:quoted_empty, false]
      end
    end

    def nullable_observed?(counts)
      null_count = counts[:missing]
      null_count += counts[:unquoted_empty] if @unquoted_empty == :null
      null_count += counts[:quoted_empty] if @quoted_empty == :null
      null_count.positive?
    end

    def add_example(list, index, observation, reason)
      return if list.size >= @max_examples

      list << Example.new(
        observation.record,
        observation.line,
        index + 1,
        reason,
        redacted_value(observation.value)
      )
    end

    def redacted_value(value)
      return value unless @redact_values
      return value unless value.is_a?(String)

      "•" * value.length
    end

    def header_for(index)
      return nil if @headers == false

      @headers[index]
    end

    def copy_row(row)
      row.map {|value| value.is_a?(String) ? value.dup : value}
    end

    def metadata_converter
      lambda do |value, info|
        @current_metadata[info.index] = info.quoted?
        value
      end
    end
  end

  ColumnTypeAnalyzer = ColumnAnalyzer

  class << self
    # Convenience entry point:
    #   report = CSV.analyze_columns(path_or_io_or_string, sample_records: 100)
    def analyze_columns(data, **options)
      ColumnAnalyzer.analyze(data, **options)
    end
  end
end
