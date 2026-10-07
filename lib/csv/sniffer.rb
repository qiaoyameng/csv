# frozen_string_literal: true

require "stringio"

class CSV
  # CSV::Sniffer guesses nothing for free: it evaluates a caller-supplied
  # set of candidate column separators (plus quote character and record
  # separators) against a bounded byte sample of the input, parses the
  # sample with the real CSV parser for each candidate, and ranks the
  # candidates by how consistent the parsed evidence is.
  #
  # The sniffer never forces a single answer.  When the evidence cannot
  # distinguish the top candidates (for example a single-column, empty, or
  # comment-only file), the result is marked ambiguous and the choice is
  # handed back to the caller together with the ranked candidates and
  # their evidence.
  #
  # Example:
  #
  #   result = CSV.sniff(io, col_seps: [",", ";", "\t"])
  #   if result.ambiguous?
  #     # ask the user, or fall back to a configured default
  #   else
  #     CSV.parse(result.reader, col_sep: result.delimiter) do |row|
  #       # ...
  #     end
  #   end
  #
  class Sniffer
    # Candidate column separators tried when the caller does not supply
    # its own list.
    DEFAULT_COL_SEPS = [",", ";", "\t", "|"].freeze

    # Candidate record separators tried when the caller does not supply
    # its own list.  +:auto+ lets the parser detect the separator.
    DEFAULT_ROW_SEPS = [:auto].freeze

    DEFAULT_QUOTE_CHAR = '"'

    # Maximum number of bytes read from the input when the caller does
    # not bound the sample itself.
    DEFAULT_SAMPLE_SIZE = 32 * 1024

    # Lines whose first field matches this pattern are treated as
    # comments and excluded from field-count evidence.
    COMMENT_PATTERN = /\A\s*#/

    # One evaluated (column separator, record separator) pair, together
    # with the evidence collected while really parsing the sample.
    class Candidate
      include Comparable

      attr_reader :col_sep, :row_sep, :score, :evidence

      def initialize(col_sep, row_sep, evidence)
        @col_sep = col_sep
        @row_sep = row_sep
        @evidence = evidence
        # Ranked lexicographically: prefer candidates that parse without
        # hard errors, then consistent field counts across data rows,
        # then actual structure (more than one field), then the most
        # data rows observed.
        @score = [
          evidence[:errors].empty? ? 1 : 0,
          evidence[:consistent] ? 1 : 0,
          (evidence[:consistent] && evidence[:fields].to_i > 1) ? 1 : 0,
          evidence[:rows],
        ]
      end

      def <=>(other)
        other.score <=> score
      end

      def rows
        evidence[:rows]
      end

      def fields
        evidence[:fields]
      end

      def consistent?
        evidence[:consistent]
      end

      def incomplete?
        evidence[:incomplete]
      end

      def errors
        evidence[:errors]
      end

      def to_h
        {
          col_sep: col_sep,
          row_sep: row_sep,
          score: score,
          rows: evidence[:rows],
          field_counts: evidence[:field_counts],
          consistent: evidence[:consistent],
          errors: evidence[:errors],
          incomplete: evidence[:incomplete],
        }
      end
    end

    # The outcome of a sniff: ranked candidates with evidence, a
    # delimiter only when the evidence is unambiguous, and a reader
    # that replays the sampled bytes so nothing is lost.
    class Result
      attr_reader :candidates, :sample, :reader

      def initialize(candidates:, sample:, reader:, truncated:)
        @candidates = candidates
        @sample = sample
        @reader = reader
        @truncated = truncated
        best_score = candidates.first&.score
        @top = candidates.take_while {|candidate| candidate.score == best_score }
      end

      # The first-ranked candidate.  May share its rank with others;
      # check #ambiguous? before trusting it.
      def best
        @top.first
      end

      # The chosen column separator, or nil when the evidence is
      # ambiguous or empty.  Never a hard guess.
      def delimiter
        col_seps = @top.map(&:col_sep).uniq
        col_seps.first if col_seps.size == 1 && evidence?
      end

      # The record separator of the chosen candidate, or nil when
      # ambiguous.
      def row_sep
        row_seps = @top.map(&:row_sep).uniq
        row_seps.first if row_seps.size == 1 && evidence?
      end

      # True when the evidence cannot single out one column separator,
      # or when there is no data-row evidence at all (empty,
      # single-column, or comment-only samples).
      def ambiguous?
        delimiter.nil?
      end

      # True when the sample ended inside a quoted field or in the
      # middle of a multibyte character, so the evidence may grow with
      # a larger sample.
      def incomplete?
        @truncated || @top.any?(&:incomplete?)
      end

      def empty?
        @sample.empty?
      end

      def to_h
        {
          delimiter: delimiter,
          row_sep: row_sep,
          ambiguous: ambiguous?,
          incomplete: incomplete?,
          empty: empty?,
          candidates: candidates.map(&:to_h),
        }
      end

      private

      def evidence?
        !@top.empty? && @top.first.rows.positive?
      end
    end

    # An IO-like reader that replays the sampled bytes verbatim and then
    # continues reading from the original source.  Used for non-seekable
    # inputs so that subsequent parsing neither loses the head of the
    # data nor reads already-consumed bytes from the source again.
    class ReplayReader
      PULL_SIZE = 32 * 1024

      def initialize(sample, source)
        @buffer = sample.dup
        @source = source
        @encoding = @buffer.encoding
        @source_eof = false
      end

      def gets(*args)
        separator, limit = normalize_gets_arguments(args)
        if separator.nil?
          read_bytes(limit)
        else
          separator = $/ if separator == ""
          read_record(separator, limit)
        end
      end

      def read(length = nil, outbuf = nil)
        result =
          if length.nil?
            pull until source_eof?
            @buffer.slice!(0, @buffer.bytesize) || +""
          elsif length.zero?
            +""
          else
            pull while @buffer.bytesize < length && !source_eof?
            return nil if @buffer.empty?
            @buffer.slice!(0, length)
          end
        outbuf&.replace(result)
        outbuf || result
      end

      def each_line(*args)
        return enum_for(__method__, *args) unless block_given?
        while (line = gets(*args))
          yield line
        end
        self
      end
      alias each each_line

      def eof?
        @buffer.empty? && source_eof?
      end
      alias eof eof?

      def external_encoding
        @encoding
      end

      def close
        @source.close if @source.respond_to?(:close)
        nil
      end

      private

      def normalize_gets_arguments(args)
        case args.size
        when 0
          [$/, nil]
        when 1
          if args[0].is_a?(Integer)
            [$/, args[0]]
          else
            [args[0], nil]
          end
        when 2
          args
        else
          raise ArgumentError,
                "wrong number of arguments (given #{args.size}, expected 0..2)"
        end
      end

      def read_record(separator, limit)
        loop do
          index = @buffer.index(separator)
          if index
            length = index + separator.bytesize
            length = limit if limit && length > limit
            return @buffer.slice!(0, length)
          end
          return @buffer.slice!(0, limit) if limit && @buffer.bytesize >= limit
          break unless pull
        end
        return nil if @buffer.empty?
        length = limit ? [limit, @buffer.bytesize].min : @buffer.bytesize
        @buffer.slice!(0, length)
      end

      def read_bytes(limit)
        if limit
          pull while @buffer.bytesize < limit && !source_eof?
          return nil if @buffer.empty?
          @buffer.slice!(0, limit)
        else
          pull until source_eof?
          return nil if @buffer.empty?
          @buffer.slice!(0, @buffer.bytesize)
        end
      end

      def source_eof?
        @source_eof || @source.nil?
      end

      def pull
        return false if source_eof?
        chunk =
          if @source.respond_to?(:readpartial)
            begin
              @source.readpartial(PULL_SIZE)
            rescue EOFError
              nil
            end
          elsif @source.respond_to?(:read)
            @source.read(PULL_SIZE)
          elsif @source.respond_to?(:gets)
            @source.gets(nil, PULL_SIZE)
          end
        if chunk.nil? || chunk.empty?
          @source_eof = true
          return false
        end
        chunk = chunk.dup
        chunk.force_encoding(@encoding)
        @buffer << chunk
        true
      end
    end

    def self.sniff(input, **options)
      new(input, **options).sniff
    end

    def initialize(input,
                   col_seps: DEFAULT_COL_SEPS,
                   row_seps: DEFAULT_ROW_SEPS,
                   quote_char: DEFAULT_QUOTE_CHAR,
                   sample_size: DEFAULT_SAMPLE_SIZE,
                   encoding: nil,
                   comment: COMMENT_PATTERN)
      @input = input
      @col_seps = col_seps
      @row_seps = row_seps
      @quote_char = quote_char
      @sample_size = sample_size
      @encoding = encoding && Encoding.find(encoding)
      @comment_pattern =
        case comment
        when nil
          nil
        when Regexp
          comment
        else
          /\A\s*#{Regexp.escape(comment.to_s)}/
        end
    end

    def sniff
      sample, reader = read_sample
      parse_sample, truncated = valid_prefix(sample)
      candidates = []
      @col_seps.each do |col_sep|
        @row_seps.each do |row_sep|
          evidence = evaluate(parse_sample, col_sep, row_sep)
          candidates << Candidate.new(col_sep, row_sep, evidence)
        end
      end
      ranked = rank(candidates)
      Result.new(candidates: ranked,
                 sample: sample,
                 reader: reader,
                 truncated: truncated)
    end

    private

    def read_sample
      if @input.is_a?(String)
        sample = @input.byteslice(0, @sample_size) || +""
        sample = sample.dup.force_encoding(sniff_encoding(@input, sample))
        [sample, StringIO.new(@input)]
      else
        position = safe_pos(@input)
        sample = read_from(@input, @sample_size) || +""
        sample = sample.dup.force_encoding(sniff_encoding(@input, sample))
        [sample, restore_or_replay(sample, position)]
      end
    end

    def sniff_encoding(input, sample)
      return @encoding if @encoding
      unless input.is_a?(String)
        if input.respond_to?(:external_encoding)
          encoding = input.external_encoding
          return encoding if encoding
        end
      end
      encoding = sample.encoding
      encoding == Encoding::ASCII_8BIT ? Encoding::UTF_8 : encoding
    end

    def safe_pos(io)
      io.pos if io.respond_to?(:pos)
    rescue IOError, SystemCallError
      nil
    end

    def read_from(io, size)
      if io.respond_to?(:read)
        io.read(size)
      elsif io.respond_to?(:gets)
        io.gets(nil, size)
      else
        raise ArgumentError,
              "input must be a String or respond to #read or #gets"
      end
    end

    def restore_or_replay(sample, position)
      if position && seek_back(@input, position)
        @input
      else
        ReplayReader.new(sample, @input)
      end
    end

    def seek_back(io, position)
      io.seek(position, IO::SEEK_SET)
      true
    rescue IOError, SystemCallError
      false
    end

    # Returns [parseable_sample, truncated].  A sample cut in the middle
    # of a multibyte character is trimmed to its valid prefix for
    # evaluation and flagged as truncated; the original bytes are kept
    # for replay.
    def valid_prefix(sample)
      return [sample, false] if sample.valid_encoding?
      1.upto(3) do |i|
        break if sample.bytesize <= i
        prefix = sample.byteslice(0, sample.bytesize - i)
        return [prefix, true] if prefix.valid_encoding?
      end
      [sample, false]
    end

    def evaluate(sample, col_sep, row_sep)
      evidence = {
        rows: 0,
        field_counts: [],
        consistent: false,
        fields: nil,
        errors: [],
        incomplete: false,
      }
      counts = []
      begin
        csv = CSV.new(StringIO.new(sample),
                      col_sep: col_sep,
                      row_sep: row_sep,
                      quote_char: @quote_char)
        while (row = csv.shift)
          next if row.empty?
          first = row[0]
          if first.is_a?(String) && @comment_pattern &&
             first.match?(@comment_pattern)
            next
          end
          counts << row.size
        end
      rescue MalformedCSVError => error
        if error.message.start_with?("Unclosed quoted field")
          # The sample was cut inside a quoted field: truncation
          # evidence, not a hard error for this candidate.
          evidence[:incomplete] = true
        else
          evidence[:errors] << error.message
        end
      rescue ArgumentError => error
        evidence[:errors] << error.message
      end
      evidence[:rows] = counts.size
      evidence[:field_counts] = counts
      if counts.any? && counts.uniq.size == 1
        evidence[:consistent] = true
        evidence[:fields] = counts.first
      end
      evidence
    end

    def rank(candidates)
      candidates
        .each_with_index
        .sort {|(a, ai), (b, bi)| (b.score <=> a.score).nonzero? || (ai <=> bi) }
        .map(&:first)
    end
  end

  class << self
    # Sniffs +input+ (a String or an IO-like object) for its column
    # separator using CSV::Sniffer.  Returns a CSV::Sniffer::Result.
    #
    # Options:
    # [<tt>:col_seps</tt>]
    #   Candidate column separators to evaluate.  Defaults to
    #   CSV::Sniffer::DEFAULT_COL_SEPS.
    # [<tt>:row_seps</tt>]
    #   Candidate record separators.  Defaults to <tt>[:auto]</tt>.
    # [<tt>:quote_char</tt>]
    #   The quote character used while evaluating.  Defaults to
    #   <tt>'"'</tt>.
    # [<tt>:sample_size</tt>]
    #   Maximum number of bytes sampled from the input.  Defaults to
    #   CSV::Sniffer::DEFAULT_SAMPLE_SIZE.
    # [<tt>:encoding</tt>]
    #   Encoding the sample is interpreted in.  Defaults to the input's
    #   external encoding, or UTF-8.
    # [<tt>:comment</tt>]
    #   A Regexp or String marking comment lines, which are excluded
    #   from field-count evidence.  Defaults to lines starting with
    #   <tt>#</tt>; pass nil to disable.
    def sniff(input, **options)
      Sniffer.sniff(input, **options)
    end
  end
end
