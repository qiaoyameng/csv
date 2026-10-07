# frozen_string_literal: true

class CSV
  # = \CSV::SegmentedReader
  #
  # A SegmentedReader reads a CSV stream that concatenates multiple
  # generations of a format: devices emit a caller-defined marker record
  # every time the layout changes, and the record right after a marker is
  # the header of the new segment.
  #
  # The stream is parsed with the regular \CSV parser first, so a marker
  # is only ever recognized at a complete record boundary: marker-like
  # text inside a quoted (possibly multi-line) field is just data and
  # never starts a segment.
  #
  # Every segment gets a freshly built header converter and column
  # mapping, so segments may order, rename, add or drop columns freely.
  # Duplicate headers are kept positionally; no column is silently
  # dropped.
  #
  # Each emitted row is a SegmentedReader::Row (a \CSV::Row subclass)
  # carrying three extra numbers:
  #
  # * +segment+: the 0-based index of the segment the row belongs to.
  # * +segment_row+: the 0-based index of the row within its segment.
  # * +global_row+: the 0-based index of the row across the whole stream.
  #
  # Example:
  #   data = <<~CSV
  #     id,name
  #     1,alice
  #     ##NEXT##
  #     name,id,tag
  #     bob,2,x
  #   CSV
  #   reader = CSV::SegmentedReader.new(data, marker: "##NEXT##",
  #                                           columns: %w[id name tag],
  #                                           missing: :NA)
  #   reader.each do |row|
  #     p [row.segment, row.segment_row, row.global_row, row.fields]
  #   end
  #   # [0, 0, 0, ["1", "alice", :NA]]
  #   # [1, 0, 1, ["2", "bob", "x"]]
  #
  # == Options
  #
  # SegmentedReader::new accepts the parsing options of CSV::new
  # (+col_sep+, +row_sep+, +quote_char+, +skip_blanks+, +converters+,
  # +header_converters+, +nil_value+, +empty_value+, ...) plus:
  #
  # [+marker+ (required)]
  #   Either a callable invoked with each raw parsed record (an \Array of
  #   fields, before any conversion) that returns truthy when the record
  #   is a segment marker, or any other object, which marks a record that
  #   consists of exactly that single field.
  # [+columns+]
  #   The unified output column set. When given, every emitted row has
  #   exactly these headers; segment headers are mapped onto them by
  #   (converted) name, duplicates included (the <i>n</i>-th occurrence
  #   of a name in a segment header feeds the <i>n</i>-th occurrence in
  #   +columns+). Declared columns a segment does not provide are filled
  #   with the +missing+ marker. A segment header that cannot be mapped
  #   onto +columns+ raises UnknownColumnError instead of being silently
  #   dropped.
  # [+missing+]
  #   The value used for declared columns a segment does not provide.
  #   Defaults to the MISSING sentinel, an object that cannot be confused
  #   with an empty field (+""+) or a +nil+ field.
  #
  # The +headers+, +return_headers+ and +unconverted_fields+ options of
  # CSV::new are managed by the reader itself and are rejected.
  #
  # == Segments
  #
  # Markers delimit segments: the records before the first marker form
  # segment 0, and every marker closes the current segment and opens the
  # next one. The first record of a segment is its header; a header
  # record with no fields at all raises BadHeaderError. A segment
  # without any record (produced by leading, consecutive or trailing
  # markers) is empty: it has no header and yields no rows, but it still
  # occupies a segment index. All segments, including empty ones, are
  # reported by #segments after reading.
  class SegmentedReader
    include Enumerable

    # The default marker used for columns a segment does not provide.
    MISSING = Object.new
    class << MISSING
      def inspect
        "CSV::SegmentedReader::MISSING"
      end
      alias_method :to_s, :inspect
    end
    MISSING.freeze

    # Raised when the record that should hold a segment header contains
    # no fields (for example a blank line).
    class BadHeaderError < MalformedCSVError
      def initialize(line_number)
        super("Segment header must be a non-empty record", line_number)
      end
    end

    # Raised when a unified +columns+ set is declared but a segment
    # header cannot be mapped onto it.
    class UnknownColumnError < RuntimeError
      def initialize(header, segment)
        super("Segment #{segment} provides column #{header.inspect} " \
              "which is not in the declared columns")
      end
    end

    # A data row emitted by SegmentedReader#each. Behaves like a
    # \CSV::Row and additionally reports its position in the stream.
    class Row < CSV::Row
      # The 0-based index of the segment this row belongs to.
      attr_reader :segment
      # The 0-based index of this row within its segment.
      attr_reader :segment_row
      # The 0-based index of this row across the whole stream.
      attr_reader :global_row

      def initialize(headers, fields, segment:, segment_row:, global_row:)
        super(headers, fields)
        @segment = segment
        @segment_row = segment_row
        @global_row = global_row
      end
    end

    # Information about one segment of the stream. See #segments.
    class Segment
      # The 0-based index of the segment.
      attr_reader :index
      # The converted headers of the segment, or +nil+ when the segment
      # had no records at all.
      attr_reader :headers
      # The number of data rows the segment produced.
      attr_reader :row_count

      def initialize(index, headers, row_count)
        @index = index
        @headers = headers
        @row_count = row_count
      end

      # Whether the segment contained no record, not even a header.
      def empty?
        @headers.nil?
      end
    end

    # The Segment objects of every segment seen so far, including empty
    # ones.
    attr_reader :segments

    def initialize(source, marker: nil, columns: nil, missing: MISSING, **options)
      raise ArgumentError, "marker is required" if marker.nil?

      @source = source
      @marker = normalize_marker(marker)
      @columns = columns
      @missing = missing

      @converters = options.delete(:converters)
      @header_converters = options.delete(:header_converters)
      @nil_value = options.delete(:nil_value)
      @empty_value = options.delete(:empty_value) { "" }
      [:headers, :return_headers, :unconverted_fields].each do |key|
        if options.key?(key)
          raise ArgumentError,
                "the #{key} option is managed by CSV::SegmentedReader"
        end
      end
      @parser_options = options

      @segments = []
    end

    # Yields each data row of the stream as a SegmentedReader::Row.
    def each
      return to_enum(__method__) unless block_given?

      @segments = []
      segment_index = 0
      segment_row = 0
      global_row = 0
      headers = nil
      column_map = nil
      fields_converter = nil
      saw_anything = false

      parser = CSV.new(@source, **@parser_options)
      parser.each do |record|
        saw_anything = true
        if @marker.call(record)
          @segments << Segment.new(segment_index, headers, segment_row)
          segment_index += 1
          segment_row = 0
          headers = nil
          column_map = nil
          fields_converter = nil
          next
        end
        if headers.nil?
          raise BadHeaderError.new(parser.lineno) if record.empty?

          header_converter = build_header_converter
          fields_converter = build_fields_converter
          headers = header_converter.convert(record, nil, parser.lineno)
          column_map = build_column_map(headers, segment_index) if @columns
        else
          fields = fields_converter.convert(record, headers, parser.lineno)
          if column_map
            row_headers = @columns
            fields = column_map.map do |source_index|
              if source_index.nil? or source_index >= fields.size
                @missing
              else
                fields[source_index]
              end
            end
          else
            row_headers = headers
          end
          yield Row.new(row_headers, fields,
                        segment: segment_index,
                        segment_row: segment_row,
                        global_row: global_row)
          segment_row += 1
          global_row += 1
        end
      end
      @segments << Segment.new(segment_index, headers, segment_row) if saw_anything
      self
    end

    # Reads the remaining rows and returns them as an \Array of
    # SegmentedReader::Row objects.
    def read
      rows = []
      each {|row| rows << row}
      rows
    end
    alias_method :readlines, :read

    private
    def normalize_marker(marker)
      if marker.respond_to?(:call)
        marker
      else
        ->(record) { record == [marker] }
      end
    end

    def build_fields_converter
      converter = FieldsConverter.new(
        nil_value: @nil_value,
        empty_value: @empty_value,
        builtin_converters_name: :Converters,
      )
      add_converters(converter, @converters)
      converter
    end

    def build_header_converter
      converter = FieldsConverter.new(
        nil_value: @nil_value,
        empty_value: @empty_value,
        accept_nil: true,
        builtin_converters_name: :HeaderConverters,
      )
      add_converters(converter, @header_converters)
      converter
    end

    def add_converters(fields_converter, converters)
      Array(converters).each do |converter|
        if converter.is_a?(Proc)
          fields_converter.add_converter(&converter)
        else
          fields_converter.add_converter(converter)
        end
      end
    end

    def build_column_map(headers, segment_index)
      declared = Hash.new(0)
      @columns.each {|column| declared[column] += 1}
      seen = Hash.new(0)
      headers.each do |header|
        seen[header] += 1
        if seen[header] > declared[header]
          raise UnknownColumnError.new(header, segment_index)
        end
      end

      positions = Hash.new {|hash, key| hash[key] = []}
      headers.each_with_index do |header, index|
        positions[header] << index
      end
      used = Hash.new(0)
      @columns.map do |column|
        occurrence = used[column]
        used[column] += 1
        positions[column][occurrence]
      end
    end
  end
end
