# frozen_string_literal: true

require "strscan"

require_relative "input_record_separator"
require_relative "row"
require_relative "table"

class CSV
  # Note: Don't use this class directly. This is an internal class.
  class Parser
    #
    # A CSV::Parser is m17n aware. The parser works in the Encoding of the IO
    # or String object being read from or written to. Your data is never transcoded
    # (unless you ask Ruby to transcode it for you) and will literally be parsed in
    # the Encoding it is in. Thus CSV will return Arrays or Rows of Strings in the
    # Encoding of your data. This is accomplished by transcoding the parser itself
    # into your Encoding.
    #

    class << self
      ARGF_OBJECT_ID = ARGF.object_id
      # Convenient method to check whether the give input reached EOF
      # or not.
      def eof?(input)
        # We can't use input != ARGF in Ractor. Because ARGF isn't a
        # shareable object.
        input.object_id != ARGF_OBJECT_ID and
          input.respond_to?(:eof) and
          input.eof?
      end
    end

    # Raised when encoding is invalid.
    class InvalidEncoding < StandardError
    end

    # Raised when unexpected case is happen.
    class UnexpectedError < StandardError
    end

    # Internal control-flow signals used by recovery mode. They carry the
    # reason for a bad record and never escape Parser#parse.
    class RecoverableFieldError < StandardError
      attr_reader :reason
      def initialize(reason)
        @reason = reason
        super(reason)
      end
    end

    class UnrecoverableFieldError < StandardError
      attr_reader :reason
      def initialize(reason)
        @reason = reason
        super(reason)
      end
    end

    # Internal sentinel meaning "the header row was consumed but must not be
    # yielded" (headers are in use but +return_headers+ is false).
    HEADER_CONSUMED = Object.new.freeze

    #
    # CSV::Scanner receives a CSV output, scans it and return the content.
    # It also controls the life cycle of the object with its methods +keep_start+,
    # +keep_end+, +keep_back+, +keep_drop+.
    #
    # Uses StringScanner (the official strscan gem). Strscan provides lexical
    # scanning operations on a String. We inherit its object and take advantage
    # on the methods. For more information, please visit:
    # https://docs.ruby-lang.org/en/master/StringScanner.html
    #
    class Scanner < StringScanner
      alias_method :scan_all, :scan

      def initialize(*args)
        super
        @keeps = []
      end

      def each_line(row_separator)
        position = pos
        rest.each_line(row_separator) do |line|
          position += line.bytesize
          self.pos = position
          yield(line)
        end
      end

      def keep_start
        @keeps.push(pos)
      end

      def keep_end
        start = @keeps.pop
        string.byteslice(start, pos - start)
      end

      def keep_back
        self.pos = @keeps.pop
      end

      def keep_drop
        @keeps.pop
      end

      def clear_keeps
        @keeps.clear
      end
    end

    #
    # CSV::InputsScanner receives IO inputs, encoding and the chunk_size.
    # It also controls the life cycle of the object with its methods +keep_start+,
    # +keep_end+, +keep_back+, +keep_drop+.
    #
    # CSV::InputsScanner.scan() tries to match with pattern at the current position.
    # If there's a match, the scanner advances the "scan pointer" and returns the matched string.
    # Otherwise, the scanner returns nil.
    #
    # CSV::InputsScanner.rest() returns the "rest" of the string (i.e. everything after the scan pointer).
    # If there is no more data (eos? = true), it returns "".
    #
    class InputsScanner
      def initialize(inputs, encoding, row_separator, chunk_size: 8192)
        @inputs = inputs.dup
        @encoding = encoding
        @row_separator = row_separator
        @chunk_size = chunk_size
        @last_scanner = @inputs.empty?
        @keeps = []
        read_chunk
      end

      def each_line(row_separator)
        return enum_for(__method__, row_separator) unless block_given?
        buffer = nil
        input = @scanner.rest
        position = @scanner.pos
        offset = 0
        n_row_separator_chars = row_separator.size
        # trace(__method__, :start, input)
        while true
          input.each_line(row_separator) do |line|
            @scanner.pos += line.bytesize
            if buffer
              if n_row_separator_chars == 2 and
                buffer.end_with?(row_separator[0]) and
                line.start_with?(row_separator[1])
                buffer << line[0]
                line = line[1..-1]
                position += buffer.bytesize + offset
                @scanner.pos = position
                offset = 0
                yield(buffer)
                buffer = nil
                next if line.empty?
              else
                buffer << line
                line = buffer
                buffer = nil
              end
            end
            if line.end_with?(row_separator)
              position += line.bytesize + offset
              @scanner.pos = position
              offset = 0
              yield(line)
            else
              buffer = line
            end
          end
          break unless read_chunk
          input = @scanner.rest
          position = @scanner.pos
          offset = -buffer.bytesize if buffer
        end
        yield(buffer) if buffer
      end

      def scan(pattern)
        # trace(__method__, pattern, :start)
        value = @scanner.scan(pattern)
        # trace(__method__, pattern, :done, :last, value) if @last_scanner
        return value if @last_scanner

        read_chunk if value and @scanner.eos?
        # trace(__method__, pattern, :done, value)
        value
      end

      def scan_all(pattern)
        # trace(__method__, pattern, :start)
        value = @scanner.scan(pattern)
        # trace(__method__, pattern, :done, :last, value) if @last_scanner
        return value if @last_scanner

        # trace(__method__, pattern, :done, :nil) if value.nil?
        return nil if value.nil?
        while @scanner.eos? and read_chunk and (sub_value = @scanner.scan(pattern))
          # trace(__method__, pattern, :sub, sub_value)
          value << sub_value
        end
        # trace(__method__, pattern, :done, value)
        value
      end

      def eos?
        @last_scanner and @scanner.eos?
      end

      def keep_start
        # trace(__method__, :start)
        adjust_last_keep
        @keeps.push([@scanner, @scanner.pos, nil])
        # trace(__method__, :done)
      end

      def keep_end
        # trace(__method__, :start)
        scanner, start, buffer = @keeps.pop
        if scanner == @scanner
          keep = @scanner.string.byteslice(start, @scanner.pos - start)
        else
          keep = @scanner.string.byteslice(0, @scanner.pos)
        end
        if buffer
          buffer << keep
          keep = buffer
        end
        # trace(__method__, :done, keep)
        keep
      end

      def keep_back
        # trace(__method__, :start)
        scanner, start, buffer = @keeps.pop
        if buffer
          # trace(__method__, :rescan, start, buffer)
          string = @scanner.string
          if scanner == @scanner
            keep = string.byteslice(start,
                                    string.bytesize - @scanner.pos - start)
          else
            keep = string
          end
          if keep and not keep.empty?
            @inputs.unshift(StringIO.new(keep))
            @last_scanner = false
          end
          @scanner = StringScanner.new(buffer)
        else
          if @scanner != scanner
            message = "scanners are different but no buffer: "
            message += "#{@scanner.inspect}(#{@scanner.object_id}): "
            message += "#{scanner.inspect}(#{scanner.object_id})"
            raise UnexpectedError, message
          end
          # trace(__method__, :repos, start, buffer)
          @scanner.pos = start
          last_scanner, last_start, last_buffer = @keeps.last
          # Drop the last buffer when the last buffer is the same data
          # in the last keep. If we keep it, we have duplicated data
          # by the next keep_back.
          if last_scanner == @scanner and
            last_buffer and
            last_buffer == last_scanner.string.byteslice(last_start, start)
            @keeps.last[2] = nil
          end
        end
        read_chunk if @scanner.eos?
      end

      def keep_drop
        _, _, buffer = @keeps.pop
        # trace(__method__, :done, :empty) unless buffer
        return unless buffer

        last_keep = @keeps.last
        # trace(__method__, :done, :no_last_keep) unless last_keep
        return unless last_keep

        if last_keep[2]
          last_keep[2] << buffer
        else
          last_keep[2] = buffer
        end
        # trace(__method__, :done)
      end

      def rest
        @scanner.rest
      end

      def check(pattern)
        @scanner.check(pattern)
      end

      private
      def trace(*args)
        pp([*args, @scanner, @scanner&.string, @scanner&.pos, @keeps])
      end

      def adjust_last_keep
        # trace(__method__, :start)

        keep = @keeps.last
        # trace(__method__, :done, :empty) if keep.nil?
        return if keep.nil?

        scanner, start, buffer = keep
        string = @scanner.string
        if @scanner != scanner
          start = 0
        end
        if start == 0 and @scanner.eos?
          keep_data = string
        else
          keep_data = string.byteslice(start, @scanner.pos - start)
        end
        if keep_data
          if buffer
            buffer << keep_data
          else
            keep[2] = keep_data.dup
          end
        end

        # trace(__method__, :done)
      end

      def read_chunk
        return false if @last_scanner

        adjust_last_keep

        input = @inputs.first
        case input
        when StringIO
          string = input.read
          raise InvalidEncoding unless string.valid_encoding?
          # trace(__method__, :stringio, string)
          @scanner = StringScanner.new(string)
          @inputs.shift
          @last_scanner = @inputs.empty?
          true
        else
          chunk = input.gets(@row_separator, @chunk_size)
          if chunk
            raise InvalidEncoding unless chunk.valid_encoding?
            # trace(__method__, :chunk, chunk)
            @scanner = StringScanner.new(chunk)
            if Parser.eof?(input)
              @inputs.shift
              @last_scanner = @inputs.empty?
            end
            true
          else
            # trace(__method__, :no_chunk)
            @scanner = StringScanner.new("".encode(@encoding))
            @inputs.shift
            @last_scanner = @inputs.empty?
            if @last_scanner
              false
            else
              read_chunk
            end
          end
        end
      end
    end

    def initialize(input, options)
      @input = input
      @options = options
      @samples = []

      prepare
    end

    def column_separator
      @column_separator
    end

    def row_separator
      @row_separator
    end

    def quote_character
      @quote_character
    end

    def field_size_limit
      @max_field_size&.succ
    end

    def max_field_size
      @max_field_size
    end

    def skip_lines
      @skip_lines
    end

    def unconverted_fields?
      @unconverted_fields
    end

    def headers
      @headers
    end

    def header_row?
      @use_headers and @headers.nil?
    end

    def return_headers?
      @return_headers
    end

    def skip_blanks?
      @skip_blanks
    end

    def liberal_parsing?
      @liberal_parsing
    end

    def lineno
      @lineno
    end

    def line
      last_line
    end

    def parse(&block)
      return to_enum(__method__) unless block_given?

      if @return_headers and @headers and @raw_headers
        headers = Row.new(@headers, @raw_headers, true)
        if @unconverted_fields
          headers = add_unconverted_fields(headers, [])
        end
        yield headers
      end

      begin
        @scanner ||= build_scanner
        if @recovery and @encoding_failure_string
          emit_encoding_failure_from_string(&block)
          return
        end
        if @recovery
          catch(:stop_recovery) do
            __send__(@parse_method, &block)
          end
        else
          __send__(@parse_method, &block)
        end
      rescue InvalidEncoding
        if @recovery
          lineno = error_lineno
          error = InvalidEncodingError.new(@encoding, lineno)
          emit_encoding_failure(error, &block)
        else
          ignore_broken_line if @scanner
          lineno = error_lineno
          error = InvalidEncodingError.new(@encoding, lineno)
          raise error
        end
      rescue UnexpectedError => error
        lineno = error_lineno
        message = "This should not be happen: #{error.message}: "
        message += "Please report this to https://github.com/ruby/csv/issues"
        raise MalformedCSVError.new(message, lineno) unless @recovery
        emit_record_failure(UnrecoverableFieldError.new(message),
                            :unrecoverable,
                            &block)
      end
    end

    def error_lineno
      @scanner ? @lineno : @lineno + 1
    end

    def eof?
      return false if @scanner.nil?
      @scanner.eos?
    end

    def use_headers?
      @use_headers
    end

    private
    # A set of tasks to prepare the file in order to parse it
    def prepare
      prepare_variable
      prepare_quote_character
      prepare_backslash
      prepare_skip_lines
      prepare_strip
      prepare_separators
      validate_strip_and_col_sep_options
      prepare_quoted
      prepare_unquoted
      prepare_line
      prepare_header
      prepare_parser
    end

    def prepare_variable
      @encoding = @options[:encoding]
      liberal_parsing = @options[:liberal_parsing]
      if liberal_parsing
        @liberal_parsing = true
        if liberal_parsing.is_a?(Hash)
          @double_quote_outside_quote =
            liberal_parsing[:double_quote_outside_quote]
          @backslash_quote = liberal_parsing[:backslash_quote]
        else
          @double_quote_outside_quote = false
          @backslash_quote = false
        end
      else
        @liberal_parsing = false
        @backslash_quote = false
      end
      @unconverted_fields = @options[:unconverted_fields]
      @max_field_size = @options[:max_field_size]
      @skip_blanks = @options[:skip_blanks]
      @fields_converter = @options[:fields_converter]
      @header_fields_converter = @options[:header_fields_converter]
      @recovery = @options[:recovery]
      @max_retained_bytes = @options[:max_retained_bytes]
      @recovery_scan_budget = @options[:recovery_scan_budget]
    end

    def prepare_quote_character
      @quote_character = @options[:quote_character]
      if @quote_character.nil?
        @escaped_quote_character = nil
        @escaped_quote = nil
      else
        @quote_character = @quote_character.to_s.encode(@encoding)
        if @quote_character.length != 1
          message = ":quote_char has to be nil or a single character String"
          raise ArgumentError, message
        end
        @escaped_quote_character = Regexp.escape(@quote_character)
        @escaped_quote = Regexp.new(@escaped_quote_character)
      end
    end

    def prepare_backslash
      return unless @backslash_quote

      @backslash_character = "\\".encode(@encoding)

      @escaped_backslash_character = Regexp.escape(@backslash_character)
      @escaped_backslash = Regexp.new(@escaped_backslash_character)
      if @quote_character.nil?
        @backslash_quote_character = nil
      else
        @backslash_quote_character =
          @backslash_character + @escaped_quote_character
      end
    end

    def prepare_skip_lines
      skip_lines = @options[:skip_lines]
      case skip_lines
      when String
        @skip_lines = skip_lines.encode(@encoding)
      when Regexp, nil
        @skip_lines = skip_lines
      else
        unless skip_lines.respond_to?(:match)
          message =
            ":skip_lines has to respond to \#match: #{skip_lines.inspect}"
          raise ArgumentError, message
        end
        @skip_lines = skip_lines
      end
    end

    def prepare_strip
      @strip = @options[:strip]
      @escaped_strip = nil
      @strip_value = nil
      @rstrip_value = nil
      if @strip.is_a?(String)
        case @strip.length
        when 0
          raise ArgumentError, ":strip must not be an empty String"
        when 1
          # ok
        else
          raise ArgumentError, ":strip doesn't support 2 or more characters yet"
        end
        @strip = @strip.encode(@encoding)
        @escaped_strip = Regexp.escape(@strip)
        if @quote_character
          @strip_value = Regexp.new(@escaped_strip +
                                    "+".encode(@encoding))
          @rstrip_value = Regexp.new(@escaped_strip +
                                     "+\\z".encode(@encoding))
        end
      elsif @strip
        strip_values = " \t\f\v"
        @escaped_strip = strip_values.encode(@encoding)
        if @quote_character
          @strip_value = Regexp.new("[#{strip_values}]+".encode(@encoding))
          @rstrip_value = Regexp.new("[#{strip_values}]+\\z".encode(@encoding))
        end
      end
    end

    begin
      StringScanner.new("x").scan("x")
    rescue TypeError
      STRING_SCANNER_SCAN_ACCEPT_STRING = false
    else
      STRING_SCANNER_SCAN_ACCEPT_STRING = true
    end

    def prepare_separators
      column_separator = @options[:column_separator]
      @column_separator = column_separator.to_s.encode(@encoding)
      if @column_separator.size < 1
        message = ":col_sep must be 1 or more characters: "
        message += column_separator.inspect
        raise ArgumentError, message
      end
      @row_separator =
        resolve_row_separator(@options[:row_separator]).encode(@encoding)

      @escaped_column_separator = Regexp.escape(@column_separator)
      @escaped_first_column_separator = Regexp.escape(@column_separator[0])
      if @column_separator.size > 1
        @column_end = Regexp.new(@escaped_column_separator)
        @column_ends = @column_separator.each_char.collect do |char|
          Regexp.new(Regexp.escape(char))
        end
        @first_column_separators = Regexp.new(@escaped_first_column_separator +
                                              "+".encode(@encoding))
      else
        if STRING_SCANNER_SCAN_ACCEPT_STRING
          @column_end = @column_separator
        else
          @column_end = Regexp.new(@escaped_column_separator)
        end
        @column_ends = nil
        @first_column_separators = nil
      end

      escaped_row_separator = Regexp.escape(@row_separator)
      @row_end = Regexp.new(escaped_row_separator)
      if @row_separator.size > 1
        @row_ends = @row_separator.each_char.collect do |char|
          Regexp.new(Regexp.escape(char))
        end
      else
        @row_ends = nil
      end

      @cr = "\r".encode(@encoding)
      @lf = "\n".encode(@encoding)
      @line_end = Regexp.new("\r\n|\n|\r".encode(@encoding))
      @not_line_end = Regexp.new("[^\r\n]+".encode(@encoding))
    end

    # This method verifies that there are no (obvious) ambiguities with the
    # provided +col_sep+ and +strip+ parsing options. For example, if +col_sep+
    # and +strip+ were both equal to +\t+, then there would be no clear way to
    # parse the input.
    def validate_strip_and_col_sep_options
      return unless @strip

      if @strip.is_a?(String)
        if @column_separator.start_with?(@strip) || @column_separator.end_with?(@strip)
          raise ArgumentError,
                "The provided strip (#{@escaped_strip}) and " \
                "col_sep (#{@escaped_column_separator}) options are incompatible."
        end
      else
        if Regexp.new("\\A[#{@escaped_strip}]|[#{@escaped_strip}]\\z").match?(@column_separator)
          raise ArgumentError,
                "The provided strip (true) and " \
                "col_sep (#{@escaped_column_separator}) options are incompatible."
        end
      end
    end

    def prepare_quoted
      if @quote_character
        @quotes = Regexp.new(@escaped_quote_character +
                             "+".encode(@encoding))
        no_quoted_values = @escaped_quote_character.dup
        if @backslash_quote
          no_quoted_values << @escaped_backslash_character
        end
        @quoted_value = Regexp.new("[^".encode(@encoding) +
                                   no_quoted_values +
                                   "]+".encode(@encoding))
      end
      if @escaped_strip
        @split_column_separator = Regexp.new(@escaped_strip +
                                             "*".encode(@encoding) +
                                             @escaped_column_separator +
                                             @escaped_strip +
                                             "*".encode(@encoding))
      else
        if @column_separator == " ".encode(@encoding)
          @split_column_separator = Regexp.new(@escaped_column_separator)
        else
          @split_column_separator = @column_separator
        end
      end
    end

    def prepare_unquoted
      return if @quote_character.nil?

      no_unquoted_values = Regexp.escape(@row_separator).encode(@encoding)
      no_unquoted_values << @escaped_first_column_separator
      unless @liberal_parsing
        no_unquoted_values << @escaped_quote_character
      end
      @unquoted_value = Regexp.new("[^".encode(@encoding) +
                                   no_unquoted_values +
                                   "]+".encode(@encoding))
    end

    def resolve_row_separator(separator)
      if separator == :auto
        cr = "\r".encode(@encoding)
        lf = "\n".encode(@encoding)
        if @input.is_a?(StringIO)
          pos = @input.pos
          separator = detect_row_separator(@input.read, cr, lf)
          @input.seek(pos)
        elsif @input.respond_to?(:gets)
          if @input.is_a?(File)
            chunk_size = 32 * 1024
          else
            chunk_size = 1024
          end
          begin
            while separator == :auto
              #
              # if we run out of data, it's probably a single line
              # (ensure will set default value)
              #
              break unless sample = @input.gets(nil, chunk_size)

              # extend sample if we're unsure of the line ending
              if sample.end_with?(cr)
                sample << (@input.gets(nil, 1) || "")
              end

              @samples << sample

              separator = detect_row_separator(sample, cr, lf)
            end
          rescue IOError
            # do nothing:  ensure will set default
          end
        end
        separator = InputRecordSeparator.value if separator == :auto
      end
      separator.to_s.encode(@encoding)
    end

    def detect_row_separator(sample, cr, lf)
      lf_index = sample.index(lf)
      if lf_index
        cr_index = sample[0, lf_index].index(cr)
      else
        cr_index = sample.index(cr)
      end
      if cr_index and lf_index
        if cr_index + 1 == lf_index
          cr + lf
        elsif cr_index < lf_index
          cr
        else
          lf
        end
      elsif cr_index
        cr
      elsif lf_index
        lf
      else
        :auto
      end
    end

    def prepare_line
      @lineno = 0
      @last_line = nil
      @scanner = nil
    end

    def last_line
      if @scanner
        @last_line ||= @scanner.keep_end
      else
        @last_line
      end
    end

    def prepare_header
      @return_headers = @options[:return_headers]

      headers = @options[:headers]
      case headers
      when Array
        @raw_headers = headers
        quoted_fields = FieldsConverter::NO_QUOTED_FIELDS
        @use_headers = true
      when String
        @raw_headers, quoted_fields = parse_headers(headers)
        @use_headers = true
      when nil, false
        @raw_headers = nil
        @use_headers = false
      else
        @raw_headers = nil
        @use_headers = true
      end
      if @raw_headers
        @headers = adjust_headers(@raw_headers, quoted_fields)
      else
        @headers = nil
      end
    end

    def parse_headers(row)
      quoted_fields = []
      converter = lambda do |field, info|
        quoted_fields << info.quoted?
        field
      end
      headers = CSV.parse_line(row,
                               col_sep:    @column_separator,
                               row_sep:    @row_separator,
                               quote_char: @quote_character,
                               converters: [converter])
      [headers, quoted_fields]
    end

    def adjust_headers(headers, quoted_fields)
      adjusted_headers = @header_fields_converter.convert(headers, nil, @lineno, quoted_fields)
      adjusted_headers.each {|h| h.freeze if h.is_a? String}
      adjusted_headers
    end

    def prepare_parser
      @may_quoted = may_quoted?
      if @quote_character.nil?
        @parse_method = :parse_no_quote
      elsif @liberal_parsing or @strip
        @parse_method = :parse_quotable_robust
      else
        @parse_method = :parse_quotable_loose
      end
    end

    def may_quoted?
      return false if @quote_character.nil?

      if @input.is_a?(StringIO)
        pos = @input.pos
        sample = @input.read
        @input.seek(pos)
      else
        return false if @samples.empty?
        sample = @samples.first
      end
      sample[0, 128].index(@quote_character)
    end

    class UnoptimizedStringIO # :nodoc:
      def initialize(string)
        @io = StringIO.new(string, "rb:#{string.encoding}")
      end

      def gets(*args)
        @io.gets(*args)
      end

      def each_line(*args, &block)
        @io.each_line(*args, &block)
      end

      def eof?
        @io.eof?
      end
    end

    SCANNER_TEST = (ENV["CSV_PARSER_SCANNER_TEST"] == "yes")
    if SCANNER_TEST
      SCANNER_TEST_CHUNK_SIZE_NAME = "CSV_PARSER_SCANNER_TEST_CHUNK_SIZE"
      SCANNER_TEST_CHUNK_SIZE_VALUE = ENV[SCANNER_TEST_CHUNK_SIZE_NAME]
      def build_scanner
        if @recovery
          string = @samples.join
          @samples.clear
          if @input.is_a?(StringIO)
            string << @input.read
          else
            while chunk = @input.gets(@row_separator, 1024 * 1024)
              string << chunk
            end
          end
          if !string.valid_encoding?
            index = string.lines(@row_separator).index { |line| !line.valid_encoding? }
            if index
              @encoding_failure_string = string
              @encoding_failure_index = index
              return nil
            end
          end
          return Scanner.new(string) unless string.empty?
        end
        inputs = @samples.collect do |sample|
          UnoptimizedStringIO.new(sample)
        end
        if @input.is_a?(StringIO)
          inputs << UnoptimizedStringIO.new(@input.read)
        else
          inputs << @input
        end
        begin
          chunk_size_value = ENV[SCANNER_TEST_CHUNK_SIZE_NAME]
        rescue # Ractor::IsolationError
          # Ractor on Ruby 3.0 can't read ENV value.
          chunk_size_value = SCANNER_TEST_CHUNK_SIZE_VALUE
        end
        chunk_size = Integer((chunk_size_value || "1"), 10)
        InputsScanner.new(inputs,
                          @encoding,
                          @row_separator,
                          chunk_size: chunk_size)
      end
    else
      def build_scanner
        string = nil
        if @recovery
          # Recovery needs stable absolute byte offsets for failure items and
          # has to re-scan bad records, so it materializes the whole input.
          string = @samples.join
          @samples.clear
          if @input.is_a?(StringIO)
            string << @input.read
          else
            while chunk = @input.gets(@row_separator, 1024 * 1024)
              string << chunk
            end
          end
          string = nil if string.empty?
        elsif @samples.empty? and @input.is_a?(StringIO)
          string = @input.read
        elsif @samples.size == 1 and Parser.eof?(@input)
          string = @samples[0]
        end
        if string
          unless string.valid_encoding?
            index = string.lines(@row_separator).index do |line|
              !line.valid_encoding?
            end
            if index
              if @recovery
                @encoding_failure_string = string
                @encoding_failure_index = index
              else
                raise InvalidEncodingError.new(@encoding, @lineno + index + 1)
              end
            end
          end
          Scanner.new(string) unless @encoding_failure_string
        else
          inputs = @samples.collect do |sample|
            StringIO.new(sample)
          end
          inputs << @input
          InputsScanner.new(inputs, @encoding, @row_separator)
        end
      end
    end

    def skip_needless_lines
      return unless @skip_lines

      until @scanner.eos?
        @scanner.keep_start
        line = @scanner.scan_all(@not_line_end) || "".encode(@encoding)
        line << @row_separator if parse_row_end
        if skip_line?(line)
          @lineno += 1
          @scanner.keep_drop
        else
          @scanner.keep_back
          return
        end
      end
    end

    def skip_line?(line)
      line = line.delete_suffix(@row_separator)
      case @skip_lines
      when String
        line.include?(@skip_lines)
      when Regexp
        @skip_lines.match?(line)
      else
        @skip_lines.match(line)
      end
    end

    def validate_field_size(field)
      return unless @max_field_size
      return if field.size <= @max_field_size
      message = "Field size exceeded: #{field.size} > #{@max_field_size}"
      field_error!(:recoverable, message)
    end

    def parse_no_quote(&block)
      @scanner.each_line(@row_separator) do |line|
        next if @skip_lines and skip_line?(line)
        original_line = line
        content = line.delete_suffix(@row_separator)
        if content.empty?
          next if @skip_blanks
          @record_start_pos = @scanner.pos - line.bytesize if @recovery
          @record_end_pos = @scanner.pos if @recovery
          @last_line = original_line
          emit_row([], &block)
        elsif @recovery
          @record_start_pos = @scanner.pos - line.bytesize
          @record_end_pos = @scanner.pos
          begin
            row = parse_no_quote_content(content)
            @last_line = original_line
            emit_row(row, &block)
          rescue RecoverableFieldError => error
            emit_record_failure(error, :field_error, &block)
          rescue UnrecoverableFieldError => error
            emit_record_failure(error, :unrecoverable, &block)
            return
          end
        else
          row = parse_no_quote_content(content)
          @last_line = original_line
          emit_row(row, &block)
        end
      end
    end

    def parse_no_quote_content(line)
      line = strip_value(line)
      row = line.split(@split_column_separator, -1)
      if @max_field_size
        row.each do |column|
          validate_field_size(column)
        end
      end
      row.each_index do |i|
        row[i] = nil if row[i].empty?
      end
      row
    end

    def parse_quotable_loose(&block)
      @scanner.keep_start
      @scanner.each_line(@row_separator) do |line|
        if @skip_lines and skip_line?(line)
          @scanner.keep_drop
          @scanner.keep_start
          next
        end
        original_line = line
        line = line.delete_suffix(@row_separator)

        begin
          if @recovery
            @record_start_pos = @scanner.pos - original_line.bytesize
            @record_end_pos = @scanner.pos
          end
          if line.empty?
            if @skip_blanks
              @scanner.keep_drop
              @scanner.keep_start
              next
            end
            row = []
            quoted_fields = FieldsConverter::NO_QUOTED_FIELDS
          elsif line.include?(@cr) or line.include?(@lf)
            @scanner.keep_back
            @parse_method = :parse_quotable_robust
            return parse_quotable_robust(&block)
          else
            row = line.split(@split_column_separator, -1)
            quoted_fields = []
            n_columns = row.size
            i = 0
            while i < n_columns
              column = row[i]
              if column.empty?
                quoted_fields << false
                row[i] = nil
              else
                n_quotes = column.count(@quote_character)
                if n_quotes.zero?
                  quoted_fields << false
                  # no quote
                elsif n_quotes == 2 and
                      column.start_with?(@quote_character) and
                      column.end_with?(@quote_character)
                  quoted_fields << true
                  row[i] = column[1..-2]
                else
                  @scanner.keep_back
                  @parse_method = :parse_quotable_robust
                  return parse_quotable_robust(&block)
                end
                validate_field_size(row[i])
              end
              i += 1
            end
          end
          @scanner.keep_drop
          @scanner.keep_start
          @last_line = original_line
          emit_row(row, quoted_fields, &block)
        rescue RecoverableFieldError => error
          @scanner.keep_drop
          @scanner.keep_start
          @record_start_pos ||= @scanner.pos - original_line.bytesize
          @record_end_pos = @scanner.pos
          emit_record_failure(error, :field_error, &block)
        rescue UnrecoverableFieldError => error
          emit_record_failure(error, :unrecoverable, &block)
          return
        end
      end
      @scanner.keep_drop
    end

    def parse_quotable_robust(&block)
      row = []
      quoted_fields = []
      skip_needless_lines
      start_row
      if @recovery
        catch(:stop_recovery) do
          parse_quotable_robust_recovery(row, quoted_fields, &block)
        end
      else
        parse_quotable_robust_strict(row, quoted_fields, &block)
      end
    end

    def parse_quotable_robust_strict(row, quoted_fields, &block)
      while true
        @quoted_column_value = false
        @unquoted_column_value = false
        @scanner.scan_all(@strip_value) if @strip_value
        value = parse_column_value
        if value
          @scanner.scan_all(@strip_value) if @strip_value
          validate_field_size(value)
        end
        if parse_column_end
          row << value
          quoted_fields << @quoted_column_value
        elsif parse_row_end
          if row.empty? and value.nil?
            emit_row([], &block) unless @skip_blanks
          else
            row << value
            quoted_fields << @quoted_column_value
            emit_row(row, quoted_fields, &block)
            row = []
            quoted_fields.clear
          end
          skip_needless_lines
          start_row
        elsif @scanner.eos?
          break if row.empty? and value.nil?
          row << value
          quoted_fields << @quoted_column_value
          emit_row(row, quoted_fields, &block)
          break
        else
          strict_field_error
        end
      end
    end

    def parse_quotable_robust_recovery(row, quoted_fields, &block)
      @record_start_pos = scanner_byte_pos
      while true
        begin
          @quoted_column_value = false
          @unquoted_column_value = false
          @scanner.scan_all(@strip_value) if @strip_value
          value = parse_column_value
          if value
            @scanner.scan_all(@strip_value) if @strip_value
            validate_field_size(value)
          end
          if parse_column_end
            row << value
            quoted_fields << @quoted_column_value
          elsif parse_row_end
            if row.empty? and value.nil?
              emit_row([], &block) unless @skip_blanks
            else
              row << value
              quoted_fields << @quoted_column_value
              emit_row(row, quoted_fields, &block)
              row = []
              quoted_fields.clear
            end
            skip_needless_lines
            start_row
            @record_start_pos = scanner_byte_pos
          elsif @scanner.eos?
            break if row.empty? and value.nil?
            row << value
            quoted_fields << @quoted_column_value
            emit_row(row, quoted_fields, &block)
            break
          else
            strict_field_error
          end
        rescue RecoverableFieldError => error
          row = []
          quoted_fields.clear
          break unless handle_record_error(error, :recoverable, &block)
          skip_needless_lines
          start_row
          @record_start_pos = scanner_byte_pos
        rescue UnrecoverableFieldError => error
          handle_record_error(error, :unrecoverable, &block)
          break
        end
      end
    end

    def strict_field_error
      if @quoted_column_value
        if liberal_parsing? and (new_line = @scanner.check(@line_end))
          message =
            "Illegal end-of-line sequence outside of a quoted field " +
            "<#{new_line.inspect}>"
        else
          message = "Any value after quoted field isn't allowed"
        end
        field_error!(:recoverable, message)
      elsif @unquoted_column_value and
            (new_line = @scanner.scan(@line_end))
        message = "Unquoted fields do not allow new line " +
                  "<#{new_line.inspect}>"
        field_error!(:unrecoverable, message)
      elsif @scanner.rest.start_with?(@quote_character)
        field_error!(:recoverable, "Illegal quoting")
      elsif (new_line = @scanner.scan(@line_end))
        message = "New line must be <#{@row_separator.inspect}> " +
                  "not <#{new_line.inspect}>"
        field_error!(:unrecoverable, message)
      else
        field_error!(:unrecoverable, "TODO: Meaningful message")
      end
    end

    def parse_column_value
      if @liberal_parsing
        quoted_value = parse_quoted_column_value
        if quoted_value
          @scanner.scan_all(@strip_value) if @strip_value
          unquoted_value = parse_unquoted_column_value
          if unquoted_value
            if @double_quote_outside_quote
              unquoted_value = unquoted_value.gsub(@quote_character * 2,
                                                   @quote_character)
              if quoted_value.empty? # %Q{""...} case
                return @quote_character + unquoted_value
              end
            end
            @quote_character + quoted_value + @quote_character + unquoted_value
          else
            quoted_value
          end
        else
          parse_unquoted_column_value
        end
      elsif @may_quoted
        parse_quoted_column_value ||
          parse_unquoted_column_value
      else
        parse_unquoted_column_value ||
          parse_quoted_column_value
      end
    end

    def parse_unquoted_column_value
      value = @scanner.scan_all(@unquoted_value)
      return nil unless value

      @unquoted_column_value = true
      if @first_column_separators
        while true
          @scanner.keep_start
          is_column_end = @column_ends.all? do |column_end|
            @scanner.scan(column_end)
          end
          @scanner.keep_back
          break if is_column_end
          sub_separator = @scanner.scan_all(@first_column_separators)
          break if sub_separator.nil?
          value << sub_separator
          sub_value = @scanner.scan_all(@unquoted_value)
          break if sub_value.nil?
          value << sub_value
        end
      end
      value.gsub!(@backslash_quote_character, @quote_character) if @backslash_quote
      if @rstrip_value
        value.gsub!(@rstrip_value, "")
      end
      value
    end

    def parse_quoted_column_value
      quotes = @scanner.scan_all(@quotes)
      return nil unless quotes

      @quoted_column_value = true
      n_quotes = quotes.size
      if (n_quotes % 2).zero?
        quotes[0, (n_quotes - 2) / 2]
      else
        value = quotes[0, n_quotes / 2]
        while true
          quoted_value = @scanner.scan_all(@quoted_value)
          value << quoted_value if quoted_value
          if @backslash_quote
            if @scanner.scan(@escaped_backslash)
              if @scanner.scan(@escaped_quote)
                value << @quote_character
              else
                value << @backslash_character
              end
              next
            end
          end

          quotes = @scanner.scan_all(@quotes)
          unless quotes
            message = "Unclosed quoted field"
            field_error!(:unrecoverable, message)
          end
          n_quotes = quotes.size
          if n_quotes == 1
            break
          else
            value << quotes[0, n_quotes / 2]
            break if (n_quotes % 2) == 1
          end
        end
        value
      end
    end

    def parse_column_end
      return true if @scanner.scan(@column_end)
      return false unless @column_ends

      @scanner.keep_start
      if @column_ends.all? {|column_end| @scanner.scan(column_end)}
        @scanner.keep_drop
        true
      else
        @scanner.keep_back
        false
      end
    end

    def parse_row_end
      return true if @scanner.scan(@row_end)
      return false unless @row_ends
      @scanner.keep_start
      if @row_ends.all? {|row_end| @scanner.scan(row_end)}
        @scanner.keep_drop
        true
      else
        @scanner.keep_back
        false
      end
    end

    def strip_value(value)
      return value unless @strip
      return value if value.nil?

      case @strip
      when String
        while value.delete_prefix!(@strip)
          # do nothing
        end
        while value.delete_suffix!(@strip)
          # do nothing
        end
      else
        value.strip!
      end
      value
    end

    def ignore_broken_line
      @scanner.scan_all(@not_line_end)
      @scanner.scan_all(@line_end)
      @lineno += 1
    end

    def start_row
      if @last_line
        @last_line = nil
      else
        @scanner.keep_drop
      end
      @scanner.keep_start
    end

    def emit_row(row, quoted_fields=FieldsConverter::NO_QUOTED_FIELDS, &block)
      @lineno += 1

      raw_row = row
      if @recovery and header_row?
        # A bad header record leaves the whole stream ambiguous: report it
        # as unrecoverable and stop.
        begin
          converted = convert_row(row, raw_row, quoted_fields)
        rescue StandardError => error
          emit_record_failure(error, :unrecoverable, &block)
          return
        end
        block.call(converted) unless converted == HEADER_CONSUMED
      elsif @recovery
        # A converter error only affects this record. The record boundary
        # was already parsed, so no resynchronization is needed and earlier
        # records are never converted again.
        begin
          converted = convert_row(row, raw_row, quoted_fields)
        rescue StandardError => error
          emit_record_failure(error, :converter_error, &block)
          return
        end
        block.call(converted) unless converted == HEADER_CONSUMED
      else
        converted = convert_row(row, raw_row, quoted_fields)
        block.call(converted) unless converted == HEADER_CONSUMED
      end
    end

    def convert_row(row, raw_row, quoted_fields)
      if @use_headers
        if @headers.nil?
          @headers = adjust_headers(row, quoted_fields)
          if @return_headers
            header_row = Row.new(@headers, row, true)
            if @unconverted_fields and not header_row.respond_to?(:unconverted_fields)
              add_unconverted_fields(header_row, row)
            end
            return header_row
          end
          return HEADER_CONSUMED
        else
          row = Row.new(@headers,
                        @fields_converter.convert(raw_row, @headers, @lineno, quoted_fields))
        end
      else
        # convert fields, if needed...
        row = @fields_converter.convert(raw_row, nil, @lineno, quoted_fields)
      end

      # inject unconverted fields and accessor, if requested...
      if @unconverted_fields and not row.respond_to?(:unconverted_fields)
        add_unconverted_fields(row, raw_row)
      end
      row
    end

    # Raises the internal field error used by recovery mode. When recovery is
    # disabled the legacy behavior (skip to the next physical line and raise a
    # CSV::MalformedCSVError) is preserved.
    def field_error!(kind, message)
      if @recovery
        if kind == :recoverable
          raise RecoverableFieldError.new(message)
        else
          raise UnrecoverableFieldError.new(message)
        end
      end
      ignore_broken_line
      raise MalformedCSVError.new(message, @lineno)
    end

    # Handles a malformed record in recovery mode. Returns +true+ when a
    # boundary was found and parsing can continue, +false+ when the failure
    # was unrecoverable and the caller must stop.
    def handle_record_error(error, kind, &block)
      boundary = resynchronize_record
      if boundary == :found
        emit_record_failure(error, :field_error, &block)
        true
      else
        emit_record_failure(error,
                            boundary == :budget ? :scan_budget_exceeded : :unclosed,
                            &block)
        false
      end
    end

    # Re-scans from the start of the bad record in a quote-aware way to find
    # the next reliable record boundary. Never uses a bare physical newline
    # because it may live inside a legitimate quoted field.
    #
    # Returns:
    # - +:found+ when a row separator was seen outside of quotes,
    # - +:unclosed+ when the input ended inside a quoted field,
    # - +:budget+ when more than +:recovery_scan_budget+ bytes were scanned
    #   without finding a reliable boundary.
    def resynchronize_record
      return :unclosed unless @scanner.respond_to?(:pos=)

      start_pos = @record_start_pos || 0
      @scanner.clear_keeps
      @scanner.pos = start_pos

      quote_bytes = @quote_character ? @quote_character.b : nil
      row_bytes = @row_separator.b
      scanned = 0
      result = :unclosed
      quote_buf = +"".b
      row_buf = +"".b
      in_quotes = false
      while true
        if scanned >= @recovery_scan_budget
          result = :budget
          break
        end
        if @scanner.eos?
          result = in_quotes ? :unclosed : :found
          break
        end
        character = @scanner.get_byte
        scanned += 1
        next unless character

        if in_quotes
          # Quotes toggle state, so doubled quotes ("") stay balanced.
          if quote_bytes
            quote_buf << character.b
            if quote_bytes.start_with?(quote_buf)
              if quote_buf == quote_bytes
                in_quotes = false
                quote_buf.clear
              end
            else
              quote_buf.clear
            end
          end
        elsif quote_bytes && consume_token(quote_bytes, character, quote_buf)
          in_quotes = true
          row_buf.clear
        elsif consume_token(row_bytes, character, row_buf)
          result = :found
          break
        end
      end
      @record_end_pos = @scanner.pos
      result
    end

    # Accumulates bytes into +buffer+ to recognize a fixed byte +token+.
    # Returns +true+ exactly when +byte+ completes the token.
    def consume_token(token, byte, buffer)
      byte = byte.b
      if buffer.empty?
        return false unless token.start_with?(byte)
        buffer << byte
      else
        buffer << byte
        buffer.clear unless token.start_with?(buffer)
      end
      return false unless buffer == token

      buffer.clear
      true
    end

    def emit_encoding_failure(cause, &block)
      @lineno += 1
      start_pos = @record_start_pos
      end_pos = scanner_byte_pos
      record = build_failure_record(cause,
                                    start_pos,
                                    end_pos,
                                    end_pos - (start_pos || end_pos),
                                    true)
      yield(record)
    end

    def emit_encoding_failure_from_string(&block)
      string = @encoding_failure_string
      index = @encoding_failure_index || 0
      start_pos = 0
      index.times do
        separator_pos = string.index(@row_separator, start_pos)
        break unless separator_pos
        start_pos = separator_pos + @row_separator.bytesize
      end
      end_pos = string.bytesize
      lineno = @lineno + index + 1
      @lineno = lineno
      cause = InvalidEncodingError.new(@encoding, lineno)
      limit = @max_retained_bytes
      retained_size = [end_pos - start_pos, limit].min
      raw = string.byteslice(start_pos, retained_size)
      failure = UnrecoverableRecord.new(lineno,
                                        [start_pos, end_pos],
                                        cause,
                                        raw,
                                        end_pos - start_pos,
                                        (end_pos - start_pos) > retained_size)
      yield(failure)
    end

    def emit_record_failure(cause, reason, &block)
      @lineno += 1
      start_pos = @record_start_pos
      end_pos = @record_end_pos || scanner_byte_pos
      byte_size = end_pos - (start_pos || end_pos)
      unrecoverable = reason != :field_error && reason != :converter_error
      record = build_failure_record(cause,
                                    start_pos,
                                    end_pos,
                                    byte_size,
                                    unrecoverable)
      @record_end_pos = nil
      yield(record)
      throw :stop_recovery if unrecoverable
    end

    def build_failure_record(cause, start_pos, end_pos, byte_size, unrecoverable)
      start_pos ||= 0
      end_pos ||= start_pos
      byte_size = [byte_size, end_pos - start_pos].max
      limit = @max_retained_bytes
      retained_size = [[byte_size, 0].max, limit].min
      raw = input_bytes&.byteslice(start_pos, retained_size)
      truncated = byte_size > retained_size
      error = cause.is_a?(MalformedCSVError) ? cause : MalformedCSVError.new(cause.message, @lineno)
      klass = unrecoverable ? UnrecoverableRecord : MalformedRecord
      klass.new(@lineno,
                [start_pos, end_pos],
                error,
                raw,
                byte_size,
                truncated)
    end

    def scanner_byte_pos
      @scanner.respond_to?(:pos) ? @scanner.pos : 0
    end

    def input_bytes
      @scanner.respond_to?(:string) ? @scanner.string : nil
    end

    # This method injects an instance variable <tt>unconverted_fields</tt> into
    # +row+ and an accessor method for +row+ called unconverted_fields().  The
    # variable is set to the contents of +fields+.
    def add_unconverted_fields(row, fields)
      class << row
        attr_reader :unconverted_fields
      end
      row.instance_variable_set(:@unconverted_fields, fields)
      row
    end
  end
end
