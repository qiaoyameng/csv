# frozen_string_literal: true

require "singleton"

class CSV
  # Sentinel used by CSV::SegmentedReader to mark a value that is absent
  # because a segment does not provide one of the requested
  # <tt>:output_columns</tt>. It is distinct from +nil+ (a blank trailing
  # field) and +""+ (an empty quoted/empty field).
  class MissingValue
    include Singleton

    def to_s
      ""
    end

    def inspect
      "#<CSV::MissingValue>"
    end
  end

  # A CSV row yielded by CSV::SegmentedReader. It wraps a CSV::Row and
  # additionally records where the row was found.
  class SegmentedRow
    extend Forwardable

    # The CSV::SegmentedReader::Segment the row belongs to.
    attr_reader :segment

    def initialize(row, segment, segment_lineno, global_lineno)
      @row = row
      @segment = segment
      @segment_lineno = segment_lineno
      @global_lineno = global_lineno
    end

    # One-based position of the row among the data rows of its segment.
    attr_reader :segment_lineno
    alias_method :segment_line_number, :segment_lineno

    # One-based position of the record in the whole stream, as reported by the
    # underlying CSV parser. Segment markers and header records are counted.
    attr_reader :global_lineno
    alias_method :global_line_number, :global_lineno

    # Number of the segment the row belongs to.
    def segment_number
      @segment.number
    end

    # The wrapped CSV::Row holding the headers and field values.
    attr_reader :row

    # Accessors forwarded to the wrapped CSV::Row.
    def_delegators :@row,
                   :[], :[]=, :field, :fetch, :fields, :values_at,
                   :headers, :to_h, :to_a, :to_csv,
                   :each, :each_pair,
                   :length, :size, :empty?,
                   :field?, :include?, :index,
                   :header_row?, :field_row?,
                   :dig, :hash, :==, :eql?, :inspect, :to_s
  end

  # Reads a single stream that concatenates several CSV sections with
  # different headers. Sections are separated by caller defined *segment
  # markers* (see CSV::SegmentedReader.new); the complete record following a
  # marker becomes the header of the new segment.
  class SegmentedReader
    include Enumerable

    # :call-seq:
    #   CSV::SegmentedReader.new(data, segment_marker: marker, **options) -> reader
    #   CSV::SegmentedReader.new(data, **options) { |record| ... } -> reader
    #
    # Returns a new segmented reader over +data+ (a \String or IO-like object,
    # as accepted by CSV.new).
    #
    # A record is treated as a segment boundary when +marker+ matches it.
    # +marker+ may be a Proc or any object responding to +===+ (an \Array of
    # fields, a \Regexp matched against the single field of a one-field
    # record, and so on); it is always called with the *already parsed* raw
    # record, so a sequence appearing inside a quoted multi-line field is
    # never mistaken for a marker. The same decision can be made with a block.
    #
    # Options:
    # [+:output_columns+] Optional unified array of column names for every
    #                     emitted row. Columns missing from a segment get
    #                     CSV::MissingValue instead of +nil+ or +""+.
    # [+:missing_value+] Object to use for missing unified columns; defaults
    #                    to the CSV::MissingValue singleton.
    # [+:header_converters+] Converters applied to each segment header.
    # [+:converters+] Converters applied to the data rows of every segment.
    #
    # All other options are CSV parsing options (such as <tt>:col_sep</tt>).
    # The +headers+, +return_headers+ and +write_headers+ options are managed
    # by the segmented reader and cannot be specified.
    def initialize(data,
                   segment_marker: nil,
                   output_columns: nil,
                   missing_value: MissingValue.instance,
                   header_converters: nil,
                   converters: nil,
                   col_sep: ",",
                   row_sep: :auto,
                   quote_char: '"',
                   field_size_limit: nil,
                   max_field_size: nil,
                   unconverted_fields: nil,
                   skip_blanks: false,
                   skip_lines: nil,
                   liberal_parsing: false,
                   internal_encoding: nil,
                   external_encoding: nil,
                   encoding: nil,
                   nil_value: nil,
                   empty_value: "",
                   strip: false,
                   &marker_block)
      if segment_marker and marker_block
        raise ArgumentError, "pass either :segment_marker or a block, not both"
      end
      @marker = marker_block || segment_marker
      unless @marker
        raise ArgumentError, "a segment marker is required"
      end
      if output_columns
        unless output_columns.is_a?(Array) and not output_columns.empty?
          raise ArgumentError, ":output_columns must be a non-empty Array"
        end
        @output_columns = output_columns
      end
      @missing_value = missing_value
      @initial_header_converters = header_converters
      @initial_converters = converters
      @data = data
      @base_options = {
        col_sep: col_sep,
        row_sep: row_sep,
        quote_char: quote_char,
        field_size_limit: field_size_limit,
        max_field_size: max_field_size,
        unconverted_fields: unconverted_fields,
        skip_blanks: skip_blanks,
        skip_lines: skip_lines,
        liberal_parsing: liberal_parsing,
        internal_encoding: internal_encoding,
        external_encoding: external_encoding,
        encoding: encoding,
        nil_value: nil_value,
        empty_value: empty_value,
        strip: strip,
      }
      @raw = nil
      reset_state
    end

    # The unified output columns, when <tt>:output_columns</tt> was given.
    attr_reader :output_columns

    # Yields each CSV::SegmentedReader::Segment in order. Segments are
    # streamed: iterating a segment yields its rows. An empty segment is
    # yielded as an empty? segment without rows.
    def each_segment
      return enum_for(:each_segment) unless block_given?

      start_iteration unless @iterating
      while (segment = open_next_segment)
        yield segment
        drain_segment(segment)
      end
      self
    end

    # Yields every data row of every segment as a CSV::SegmentedRow.
    def each
      return enum_for(:each) unless block_given?

      each_segment do |segment|
        segment.each do |row|
          yield row
        end
      end
    end

    # Returns all segments as an Array. Each segment's rows are materialized.
    def segments
      each_segment.to_a
    end

    # Returns the next data row of the stream as a CSV::SegmentedRow,
    # transparently crossing segment boundaries, or +nil+ at end of input.
    def shift
      start_iteration unless @iterating
      loop do
        if @current_segment
          row = @current_segment.shift
          return row if row
          @current_segment = nil
        end
        segment = open_next_segment
        return nil if segment.nil?
        @current_segment = segment
      end
    end
    alias_method :gets, :shift
    alias_method :readline, :shift

    # Rewinds the wrapped input and resets segment/line counters so the
    # stream can be read again. The wrapped IO must support +rewind+.
    def rewind
      @raw&.rewind
      reset_state
      self
    end

    # One section of the stream: a header plus the rows up to the next
    # segment marker.
    class Segment
      include Enumerable

      def initialize(reader, number, marker_lineno)
        @reader = reader
        @number = number
        @marker_lineno = marker_lineno
        @raw_headers = nil
        @headers = nil
        @header_lineno = nil
        @exhausted = false
      end

      # One-based number of the segment in the stream.
      attr_reader :number
      alias_method :segment_number, :number

      # Global line number of the marker that opened the segment, or +nil+
      # for the leading segment (data before the first marker).
      attr_reader :marker_lineno
      alias_method :marker_line_number, :marker_lineno

      # Global line number of the header record, or +nil+ for an empty
      # segment.
      attr_reader :header_lineno
      alias_method :header_line_number, :header_lineno

      # The converted header fields. Repeated names are kept in order; the
      # segment never silently drops a column.
      attr_reader :headers

      # The header fields as parsed, before header converters ran.
      attr_reader :raw_headers

      # Returns +true+ when the segment has no usable header: the stream
      # ended right after the opening marker, or the marker was
      # immediately followed by another marker. A segment that has a
      # header followed by zero data rows is not considered empty.
      def empty?
        @headers.nil?
      end

      # Returns the next data row of the segment as a CSV::SegmentedRow,
      # or +nil+ when the segment ends (at a segment marker or end of
      # input). The header record is not returned.
      def shift
        return nil if empty? or @exhausted

        record, lineno = @reader.shift_record
        if record.nil?
          @exhausted = true
          return nil
        end
        if @reader.marker?(record)
          @reader.queue_marker(lineno)
          @exhausted = true
          return nil
        end
        @segment_lineno = (@segment_lineno || 0) + 1
        build_row(record, lineno, @segment_lineno)
      end
      alias_method :gets, :shift
      alias_method :readline, :shift

      # Yields the data rows of the segment as CSV::SegmentedRow objects.
      # The header record is not yielded.
      def each
        return enum_for(:each) unless block_given?

        while (row = shift)
          yield row
        end
        self
      end

      # @private
      def bind_header(raw_headers, header_lineno)
        @raw_headers = raw_headers
        @header_lineno = header_lineno
        @headers = @reader.convert_header(raw_headers)
        @projection = build_projection(@headers)
      end

      # @private
      def mark_exhausted
        @exhausted = true
      end

      # @private
      def exhausted?
        @exhausted
      end

      private

      def build_row(record, global_lineno, segment_lineno)
        values = @reader.convert_fields(record, @headers, global_lineno)
        if @projection
          projected = @projection.map do |index|
            index.nil? ? @reader.missing_value : values.fetch(index, nil)
          end
          row = CSV::Row.new(@reader.output_columns, projected)
        else
          row = CSV::Row.new(@headers, values)
        end
        SegmentedRow.new(row, self, segment_lineno, global_lineno)
      end

      # Maps each unified output column to the position of its matching
      # header occurrence, honoring repeated headers by position.
      def build_projection(headers)
        return nil unless @reader.output_columns

        positions = {}
        headers.each_with_index do |header, index|
          (positions[header] ||= []) << index
        end
        seen = Hash.new(0)
        @reader.output_columns.map do |column|
          occurrence = seen[column]
          seen[column] += 1
          positions.fetch(column, [])[occurrence]
        end
      end
    end

    # @private
    def marker?(record)
      if @marker.is_a?(Regexp) and record.size == 1
        @marker.match?(record[0].to_s)
      else
        @marker === record
      end
    end

    # @private
    def missing_value
      @missing_value
    end

    # @private
    def queue_marker(lineno)
      @pending_marker_lineno = lineno
    end

    # @private
    def shift_record
      record = @raw.shift
      if record.nil?
        @at_eof = true
        [nil, nil]
      else
        [record, @raw.lineno]
      end
    end

    # @private
    def convert_header(raw_headers)
      converter = build_fields_converter(@initial_header_converters,
                                         :HeaderConverters,
                                         accept_nil: true)
      converter.convert(raw_headers, nil, 0)
    end

    # @private
    def convert_fields(fields, headers, lineno)
      converter = build_fields_converter(@initial_converters, :Converters)
      converter.convert(fields, headers, lineno)
    end

    private

    def reset_state
      @iterating = false
      @at_eof = false
      @pending_marker_lineno = nil
      @next_segment_number = 1
      @leading_segment_used = false
      @current_segment = nil
    end

    def start_iteration
      build_raw_csv
      @iterating = true
    end

    def build_raw_csv
      options = @base_options.merge(headers: false,
                                    return_headers: false,
                                    write_headers: nil)
      @raw = CSV.new(@data, **options)
      @at_eof = false
      @pending_marker_lineno = nil
      @next_segment_number = 1
      @leading_segment_used = false
      @current_segment = nil
    end

    # Pulls the next record, transparently skipping records that are blank
    # lines ignored by the parser (skip_blanks).
    def next_data_record
      loop do
        record, lineno = shift_record
        return [nil, nil] if record.nil?
        return [record, lineno] unless record.empty? && @base_options[:skip_blanks]
      end
    end

    def open_next_segment
      return nil if @at_eof && @pending_marker_lineno.nil?

      number = @next_segment_number
      @next_segment_number += 1
      if @pending_marker_lineno
        marker_lineno = @pending_marker_lineno
        @pending_marker_lineno = nil
      elsif @leading_segment_used
        return nil
      else
        @leading_segment_used = true
        marker_lineno = nil
      end

      record, lineno = next_data_record
      if record.nil?
        return Segment.new(self, number, marker_lineno)
      end

      if marker?(record)
        # Leading or consecutive marker: the current segment is empty and
        # the marker opens the segment that follows it.
        opening_lineno = marker_lineno || lineno
        queue_marker(lineno)
        return Segment.new(self, number, opening_lineno).tap(&:mark_exhausted)
      end

      segment = Segment.new(self, number, marker_lineno)

      if record.empty?
        segment.mark_exhausted
        message = "missing or empty header for segment #{number}"
        raise MissingHeaderError.new(message, lineno, segment)
      end

      segment.bind_header(record, lineno)
      segment
    end

    def drain_segment(segment)
      # Consume any rows the caller did not pull, so the next segment
      # opens at a marker boundary. shift queues the marker itself.
      nil until segment.exhausted? or segment.shift.nil?
    end

    def build_fields_converter(initial, builtin, accept_nil: false)
      converter = FieldsConverter.new(
        builtin_converters_name: builtin,
        accept_nil: accept_nil,
        nil_value: @base_options[:nil_value],
        empty_value: @base_options[:empty_value])
      normalize_converters(initial).each do |name, block|
        converter.add_converter(name, &block)
      end
      converter
    end

    def normalize_converters(converters)
      converters = Array(converters)
      converters.map do |converter|
        if converter.respond_to?(:call)
          [nil, converter]
        else
          [converter, nil]
        end
      end
    end
  end
end
