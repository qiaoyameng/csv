# frozen_string_literal: true

require "stringio"
require "strscan"

class CSV
  # Internal implementation of CSV.sniff. The public entry point is
  # CSV.sniff; the classes here are not part of the public API.
  module Sniffing
    # An IO wrapper used when sniffing consumes bytes from a source that cannot
    # be rewound (a pipe, socket, or other non seekable IO). It first replays
    # the bytes already read for sniffing and then continues streaming from the
    # source. This keeps the head of the data available for later parsing
    # without reading those bytes from the source a second time.
    #
    # The parser reads its input with +gets(record_separator, chunk_size)+ and
    # +gets(nil, chunk_size)+ and checks +eof?+; only those IO behaviors are
    # implemented, plus the accessors needed for encoding detection.
    class ReplayIO
      def initialize(prefix, source, encoding)
        @chunks = [prefix.b]
        @source = source
        @encoding = encoding
        @source_eof = false
      end

      # The parser reads input with gets(record_separator, chunk_size) and
      # gets(nil, chunk_size). Both forms return up to +limit+ bytes; a
      # separator argument does not shrink the read (the parser splits lines
      # itself). Returns nil at EOF and never ends a chunk mid multibyte char.
      def gets(separator = nil, limit = nil)
        return read_line(separator) if separator && limit.nil?
        bounded = read_bounded(limit || (1 << 16))
        return nil if bounded.nil?
        complete_trailing_character(bounded)
      end

      def read(length = nil, outbuf = nil)
        if length.nil?
          result = "".b
          while chunk = read_bounded(1 << 16)
            result << chunk
          end
        else
          result = read_bounded(length) || "".b.force_encoding(@encoding)
        end
        if outbuf
          outbuf.replace(result)
          outbuf
        else
          result.empty? && length ? nil : result
        end
      end

      def eof?
        ensure_chunk
        @chunks.empty?
      end
      alias eof eof?

      def close
        @source.close if @source.respond_to?(:close)
        nil
      end

      def closed?
        @source.respond_to?(:closed?) ? @source.closed? : false
      end

      def external_encoding
        @encoding
      end

      def internal_encoding
        nil
      end

      def path
        @source.path if @source.respond_to?(:path)
      end

      def respond_to_missing?(name, include_private = false)
        @source.respond_to?(name, include_private) || super
      end

      def method_missing(name, *args, **kwargs, &block)
        if @source.respond_to?(name)
          @source.public_send(name, *args, **kwargs, &block)
        else
          super
        end
      end

      private

      # Read exactly up to +length+ bytes from the queued chunks (refilling from
      # the source as needed).
      def read_bounded(length)
        data = "".b
        while data.bytesize < length
          ensure_chunk
          break if @chunks.empty?
          chunk = @chunks.first
          take = length - data.bytesize
          if chunk.bytesize <= take
            data << chunk
            @chunks.shift
          else
            data << chunk.byteslice(0, take)
            @chunks[0] = chunk.byteslice(take, chunk.bytesize - take)
          end
        end
        data.empty? ? nil : data
      end

      # Line read: return bytes up to and including +separator+, splitting a
      # chunk that contains the separator and queuing the rest.
      def read_line(separator)
        data = "".b
        loop do
          ensure_chunk
          return (data.empty? ? nil : data.force_encoding(@encoding)) if @chunks.empty?
          chunk = @chunks.first
          index = chunk.index(separator)
          if index
            end_pos = index + separator.bytesize
            data << chunk.byteslice(0, end_pos)
            if end_pos == chunk.bytesize
              @chunks.shift
            else
              @chunks[0] = chunk.byteslice(end_pos, chunk.bytesize - end_pos)
            end
            return data.force_encoding(@encoding)
          else
            data << chunk
            @chunks.shift
          end
        end
      end

      def ensure_chunk
        return unless @chunks.empty? && !@source_eof
        chunk = source_read(1 << 16)
        @chunks << chunk if chunk
      end

      def source_read(length)
        return nil if @source_eof
        chunk = @source.read(length)
        if chunk.nil? || chunk.empty?
          @source_eof = true
          nil
        else
          chunk.b
        end
      end

      # A bounded read may stop inside a multibyte character; read enough more
      # bytes to finish that trailing character.
      def complete_trailing_character(data)
        return data.force_encoding(@encoding) if @encoding == Encoding::ASCII_8BIT
        until data.dup.force_encoding(@encoding).valid_encoding?
          extra = read_bounded(4)
          break unless extra
          data << extra
        end
        data.force_encoding(@encoding)
      end
    end
  end
end

class CSV
  module Sniffing
    # One evaluated (record separator, column separator, quote character)
    # combination, with the evidence gathered from parsing the bounded sample.
    Candidate = Struct.new(:row_separator,
                           :column_separator,
                           :quote_character,
                           :resolved_row_separator,
                           :status,
                           :score,
                           :confidence,
                           :consistent,
                           :field_count,
                           :data_row_count,
                           :separator_count,
                           :incomplete,
                           :incomplete_reasons,
                           :error,
                           :evidence,
                           :rows,
                           keyword_init: true) do
      def acceptable?
        status == :ok || status == :incomplete
      end

      def strong?
        acceptable? && consistent && field_count >= 2 && data_row_count >= 2
      end

      def multi_column?
        acceptable? && field_count >= 2
      end
    end

    # The object returned by CSV.sniff. It exposes the ranked candidates and
    # their evidence, reports ambiguity instead of forcing a choice, and (for
    # stream input) can hand back a reader seeded with the consumed sample.
    class SniffResult
      attr_reader :sample, :encoding, :incomplete, :incomplete_reasons

      def initialize(candidates, sample, eof, encoding, source, input, parse_options)
        @all_candidates = candidates
        @sample = sample
        @eof = eof
        @encoding = encoding
        @source = source
        @input = input
        @parse_options = parse_options
        @replay_io = nil
        rank!
      end

      # Candidates in best-first order, including rejected combinations.
      def candidates
        @ranked
      end

      def accepted
        @accepted
      end

      def rejected
        @rejected
      end

      # The top ranked candidate, even when the result is ambiguous.
      def best
        @ranked.first
      end

      # True when more than one candidate ties at the top and cannot be told
      # apart from the available evidence.
      def ambiguous?
        @ambiguous
      end

      def ambiguity_reason
        @ambiguity_reason
      end

      # The indistinguishable candidates sharing the top rank; empty when there
      # is a unique winner.
      def tied
        @tied
      end

      # A unique winning combination, or nil when the evidence is ambiguous or
      # insufficient (empty/single-column data). The caller decides what to do
      # when this is nil.
      def decision
        @decision
      end

      def col_sep
        @decision&.column_separator
      end
      alias column_separator col_sep

      def row_sep
        @decision&.resolved_row_separator
      end
      alias record_separator row_sep

      def quote_char
        @decision_quote
      end
      alias quote_character quote_char

      # True when the quote character could not be established from the sample.
      def quote_inconclusive?
        @quote_inconclusive
      end

      def empty?
        @empty
      end

      def single_column?
        @single_column
      end

      def complete?
        !@incomplete
      end

      def eof?
        @eof
      end

      def sample_bytes
        @sample.bytesize
      end

      # A reader over the whole input that starts with the bytes sniffed away.
      # For String input this is a fresh CSV over the same content; for IO it
      # wraps the source with a ReplayIO so no bytes are lost or re-read.
      def reader(**overrides)
        build_csv(decision_or_raise, overrides)
      end
      alias csv reader

      # The raw IO (replaying sniffed bytes first) for callers who want to
      # choose a candidate themselves before parsing.
      def replay_io
        build_io
      end

      # Parse with an explicit candidate selection (a Candidate or an options
      # Hash such as +col_sep:+), bypassing the unique-winner check.
      def parse(candidate = nil, **overrides, &block)
        chosen = resolve_choice(candidate, overrides)
        csv = build_csv(chosen, overrides)
        return csv.read unless block_given?
        csv.each(&block)
        csv
      end

      def each(candidate = nil, **overrides, &block)
        raise ArgumentError, "a block is required" unless block_given?
        parse(candidate, **overrides, &block)
      end

      def inspect
        "#<#{self.class.name} decision=#{@decision.inspect} " \
          "ambiguous=#{@ambiguous.inspect} candidates=#{@ranked.size} " \
          "sample_bytes=#{@sample.bytesize} incomplete=#{@incomplete.inspect}>"
      end

      private

      def rank!
        @accepted0 = @all_candidates.select(&:acceptable?)
        @rejected = @all_candidates.reject(&:acceptable?)

        @incomplete = @accepted0.any? {|candidate| candidate.incomplete}
        @incomplete_reasons =
          @accepted0.flat_map(&:incomplete_reasons).uniq
        @empty = @sample.empty? ||
                 @accepted0.all? {|candidate| candidate.data_row_count.zero?}

        collapse_quote_variants!
        compute_winner!

        order = preference_order
        @accepted = @accepted0.sort_by do |candidate|
          [
            candidate.strong? ? 0 : (candidate.multi_column? ? 1 : 2),
            -candidate.score,
            order.index(candidate.column_separator) || 99,
            order.index(candidate.quote_character&.to_s) || 99,
          ]
        end
        @ranked = @accepted + @rejected
      end

      # When several quote characters produce byte identical output because
      # none of them actually acts as a quote in the sample, they carry no
      # distinguishing information; keep one representative per separator and
      # remember that the quote character is inconclusive.
      def collapse_quote_variants!
        kept = []
        groups = @accepted0.group_by do |candidate|
          [candidate.column_separator, candidate.resolved_row_separator]
        end
        groups.each_value do |same_separator|
          same_separator.group_by {|candidate| fingerprint(candidate)}.
            each_value do |group|
              if group.size > 1 && group.none? {|candidate| candidate.evidence[:quote_used]}
                representative = group.min_by do |candidate|
                  candidate.quote_character.to_s
                end
                group.each do |candidate|
                  candidate.status = :redundant_quote unless candidate.equal?(representative)
                end
                representative.evidence[:quote_inconclusive] = true
                kept << representative
              else
                kept.concat(group)
              end
            end
        end
        @accepted0 = kept.select(&:acceptable?)
      end

      def compute_winner!
        @ambiguous = false
        @tied = []
        @decision = nil
        @decision_quote = nil
        @quote_inconclusive = false
        @single_column = false

        pool =
          if @accepted0.any?(&:strong?)
            @accepted0.select(&:strong?)
          elsif @accepted0.any?(&:multi_column?)
            @accepted0.select(&:multi_column?)
          else
            @accepted0
          end

        if @empty
          @single_column = false
          @ambiguity_reason = :empty
          @ambiguous = true
          return
        end

        if pool.empty? || pool.all? {|candidate| candidate.field_count <= 1}
          @single_column = true
          @ambiguity_reason = :single_column
          @ambiguous = true
          return
        end

        top_score = pool.map(&:score).max
        winners = pool.select {|candidate| candidate.score == top_score}
        distinguishable = winners.uniq do |candidate|
          [candidate.column_separator,
           candidate.resolved_row_separator,
           fingerprint(candidate)]
        end

        if distinguishable.size > 1
          @ambiguous = true
          @tied = distinguishable
          @ambiguity_reason = :indistinguishable_tie
          return
        end

        winner = winners.first
        @decision = winner
        @quote_inconclusive = !!winner.evidence[:quote_inconclusive]
        @decision_quote =
          if @quote_inconclusive
            nil
          else
            winner.quote_character
          end
      end

      def fingerprint(candidate)
        candidate.rows.collect do |row|
          row.is_a?(Array) ? row : row.to_a
        end
      end

      def preference_order
        [",", ";", "\t", "|", ":"]
      end

      def decision_or_raise
        unless @decision
          raise ArgumentError,
                "CSV dialect is ambiguous (#{@ambiguity_reason}); " \
                "pass an explicit candidate/options to #parse"
        end
        @decision
      end

      def resolve_choice(candidate, overrides)
        return @decision if candidate.nil? && overrides.empty? && @decision
        if candidate.is_a?(Candidate)
          candidate
        else
          opts = candidate.is_a?(Hash) ? candidate.merge(overrides) : overrides
          build_synthetic_candidate(opts)
        end
      end

      def build_synthetic_candidate(opts)
        chosen = @decision
        Candidate.new(
          row_separator: opts.fetch(:row_sep, chosen&.row_separator || :auto),
          column_separator: opts.fetch(:col_sep,
                                       chosen&.column_separator || ","),
          quote_character: opts.key?(:quote_char) ? opts[:quote_char] :
                            chosen&.quote_character,
          resolved_row_separator: nil,
          status: :ok,
          incomplete: false
        )
      end

      def chosen_options(candidate, overrides)
        options = @parse_options.merge(overrides)
        options[:col_sep] = candidate.column_separator
        options[:row_sep] = candidate.row_separator
        options[:quote_char] = candidate.quote_character unless
          candidate.quote_character.nil? && !overrides.key?(:quote_char)
        options.delete(:skip_lines) if options[:skip_lines].nil?
        options
      end

      def build_csv(candidate, overrides)
        options = chosen_options(candidate, overrides)
        CSV.new(build_io, **options)
      end

      def build_io
        if @source.nil?
          StringIO.new(@input)
        else
          @replay_io ||=
            Sniffing::ReplayIO.new(@sample, @source, @encoding)
        end
      end
    end
  end
end

class CSV
  module Sniffing
    # Evaluates caller supplied candidate separators against a bounded sample by
    # running the real parser for each combination.
    class Sniffer
      DEFAULT_COLUMN_SEPARATORS = [",", ";", "\t", "|", ":"]
      DEFAULT_QUOTE_CHARACTERS  = ['"', "'"]
      DEFAULT_ROW_SEPARATORS    = [:auto]
      DEFAULT_SAMPLE_BYTES      = 65_536

      def initialize(input,
                     column_separators: nil,
                     quote_characters: nil,
                     row_separators: nil,
                     sample_bytes: nil,
                     encoding: nil,
                     **parse_options)
        @input = input
        @column_separators =
          normalize(column_separators, DEFAULT_COLUMN_SEPARATORS)
        @quote_characters =
          normalize_quotes(quote_characters, DEFAULT_QUOTE_CHARACTERS)
        @row_separators =
          normalize(row_separators, DEFAULT_ROW_SEPARATORS)
        @sample_bytes = normalize_sample_bytes(sample_bytes)
        @requested_encoding = encoding
        @parse_options = parse_options
      end

      def sniff
        raw_sample, source, eof, cut_at_limit = take_sample
        encoding = resolve_encoding(raw_sample, source)
        sample = raw_sample.dup.force_encoding(encoding)
        @encoding = encoding
        @sample_eof = eof
        # True only when the sample was sliced by the byte budget; a sample that
        # ends mid unit because the whole input ends mid unit is malformed tail,
        # not a sniffing boundary artifact.
        @cut_at_limit = cut_at_limit

        candidates = build_combinations.collect do |combination|
          evaluate(sample, *combination)
        end

        SniffResult.new(candidates,
                        sample,
                        eof,
                        encoding,
                        source,
                        @input,
                        @parse_options)
      end

      private

      def normalize(candidates, defaults)
        candidates = defaults if candidates.nil?
        candidates = Array(candidates)
        candidates = defaults if candidates.empty?
        candidates.uniq
      end

      def normalize_quotes(candidates, defaults)
        normalize(candidates, defaults)
      end

      def normalize_sample_bytes(value)
        value ||= DEFAULT_SAMPLE_BYTES
        value = Integer(value)
        raise ArgumentError, "sample_bytes must be positive" if value <= 0
        value
      end

      # Returns [raw_binary_sample, source_io_or_nil, eof_reached].
      def take_sample
        case @input
        when String
          data = @input.b
          if data.bytesize <= @sample_bytes
            [data, nil, true, false]
          else
            [data.byteslice(0, @sample_bytes), nil, false, true]
          end
        else
          sample = "".b
          eof = false
          while sample.bytesize < @sample_bytes
            chunk = @input.read(@sample_bytes - sample.bytesize)
            if chunk.nil? || chunk.empty?
              eof = true
              break
            end
            sample << chunk.b
          end
          eof ||= sample.bytesize < @sample_bytes
          [sample, @input, eof, !eof]
        end
      end

      def resolve_encoding(sample, source)
        if @requested_encoding
          return Encoding.find(@requested_encoding)
        end
        if source
          internal = source.internal_encoding if source.respond_to?(:internal_encoding)
          external = source.external_encoding if source.respond_to?(:external_encoding)
          encoding = internal || external
          return encoding if encoding
        end
        if sample.valid_encoding? && sample.encoding != Encoding::ASCII_8BIT
          sample.encoding
        elsif sample.ascii_only?
          Encoding::UTF_8
        else
          Encoding::ASCII_8BIT
        end
      end

      def build_combinations
        @row_separators.product(@column_separators, @quote_characters)
      end

      def evaluate(sample, row_separator, column_separator, quote_character)
        prefix, reasons, resolved =
          evaluation_prefix(sample, row_separator, quote_character)

        if prefix.empty?
          return empty_candidate(row_separator, column_separator,
                                 quote_character, resolved, sample, reasons)
        end

        @quoted_recorder = []
        parser = build_parser(prefix, row_separator,
                              column_separator, quote_character)
        rows = []
        begin
          parser.parse {|row| rows << row}
        rescue MalformedCSVError => error
          reason = truncation_reason(error)
          if reason && !@sample_eof
            return truncated_candidate(error, reason, reasons, sample, prefix,
                                       parser, row_separator, column_separator,
                                       quote_character, rows)
          end
          return invalid_candidate(error, sample, prefix, parser,
                                   row_separator, column_separator,
                                   quote_character, reasons, rows)
        rescue Parser::InvalidEncoding
          return encoding_candidate(sample, prefix, parser,
                                    row_separator, column_separator,
                                    quote_character, reasons, rows)
        end

        row_fit = row_separator_fit(prefix, row_separator,
                                    parser.row_separator, rows)
        metrics = score(rows, @quoted_recorder, row_fit)
        status = reasons.any? ? :incomplete : :ok
        evidence = build_evidence(sample, prefix, parser, rows, reasons,
                                  quote_character, column_separator, row_fit)
        Candidate.new(
          row_separator: row_separator,
          column_separator: column_separator,
          quote_character: quote_character,
          resolved_row_separator: parser.row_separator,
          status: status,
          score: metrics[:score],
          confidence: confidence(metrics, reasons),
          consistent: metrics[:consistent],
          field_count: metrics[:field_count],
          data_row_count: metrics[:data_row_count],
          separator_count: metrics[:separator_count],
          incomplete: reasons.any?,
          incomplete_reasons: reasons,
          error: nil,
          evidence: evidence,
          rows: rows,
        )
      end

      # Reduces the sample to a prefix that is closed relative to record and
      # quote boundaries; records why the remainder was dropped.
      def evaluation_prefix(sample, row_separator, quote_character)
        reasons = []
        prefix = sample.b.dup.force_encoding(@encoding)
        resolved =
          row_separator == :auto ? detect_row_separator(prefix) : row_separator.to_s.b

        unless prefix.valid_encoding?
          trimmed = trim_invalid_multibyte(prefix)
          unless trimmed.bytesize == prefix.bytesize
            reasons << :multibyte_boundary if @cut_at_limit
          end
          prefix = trimmed
        end

        # A dangling quote can live in the trailing partial record, so check
        # it on the multibyte-valid prefix before trimming to a record end.
        if quote_character && dangling_quote?(prefix, quote_character)
          if @cut_at_limit
            # Bounded sample cut inside a quoted field: mark incomplete and
            # evaluate only the closed prefix so this candidate is not wrongly
            # rejected.
            reasons << :quote_boundary
            closed = trim_to_closed_quote(prefix, quote_character, resolved)
            if closed && !closed.empty?
              prefix = closed
              if resolved && !prefix.end_with?(resolved)
                prefix = trim_to_record_boundary(prefix, resolved)
              end
            elsif resolved
              prefix = trim_to_record_boundary(prefix, resolved)
              reasons << :record_boundary
            end
          end
          # When the whole input ends on an open quote, leave the sample as is
          # so the real parser marks it invalid.
        elsif resolved && !prefix.end_with?(resolved)
          cut = trim_to_record_boundary(prefix, resolved)
          if cut.bytesize < prefix.bytesize
            reasons << :record_boundary if @cut_at_limit
            prefix = cut
          end
        end

        [prefix, reasons.uniq, resolved]
      end

      def trim_invalid_multibyte(sample)
        cut = sample.bytesize
        cut -= 1 until cut.zero? ||
                       sample.byteslice(0, cut).dup.
                         force_encoding(@encoding).valid_encoding?
        sample.byteslice(0, cut)
      end

      def detect_row_separator(sample)
        lf_index = sample.index("\n".b)
        cr_index =
          if lf_index
            sample.byteslice(0, lf_index).index("\r".b)
          else
            sample.index("\r".b)
          end
        if cr_index && lf_index
          if cr_index + 1 == lf_index
            "\r\n".b
          elsif cr_index < lf_index
            "\r".b
          else
            "\n".b
          end
        elsif cr_index
          "\r".b
        elsif lf_index
          "\n".b
        end
      end

      def trim_to_record_boundary(sample, record_separator)
        index = sample.rindex(record_separator)
        return sample if index.nil?
        sample.byteslice(0, index + record_separator.bytesize)
      end

      def dangling_quote?(sample, quote_character)
        text = sample.dup.force_encoding(@encoding)
        text.count(quote_character.encode(@encoding)).odd?
      rescue Encoding::UndefinedConversionError
        sample.b.count(quote_character.b).odd?
      end

      def trim_to_closed_quote(sample, quote_character, record_separator)
        text = sample.dup.force_encoding(@encoding)
        quote = quote_character.encode(@encoding)
        scanner = StringScanner.new(text)
        last_good = 0
        while (index = scanner.rest.index(quote))
          scanner.pos += index + quote.bytesize
          seen = scanner.string.byteslice(0, scanner.pos)
          last_good = scanner.pos if seen.count(quote).even?
        end
        prefix = text.byteslice(0, last_good)
        prefix
      end

      def truncation_reason(error)
        case error.message
        when /Unclosed quoted field/
          :quote_boundary
        when /New line must be/
          :record_boundary
        end
      end

      def build_fields_converter
        recorder = @quoted_recorder
        converter = FieldsConverter.new(nil_value: nil, empty_value: "")
        tracer = lambda do |field, info|
          recorder << info.quoted?
          field
        end
        converter.add_converter(nil, &tracer)
        converter
      end

      def build_parser(prefix, row_separator, column_separator, quote_character)
        io = StringIO.new(prefix)
        encoding = @encoding
        options = {
          column_separator: column_separator.to_s,
          row_separator: row_separator,
          quote_character: quote_character,
          max_field_size: nil,
          unconverted_fields: nil,
          headers: false,
          return_headers: false,
          skip_blanks: false,
          skip_lines: @parse_options[:skip_lines],
          liberal_parsing: @parse_options[:liberal_parsing] || false,
          encoding: encoding,
          nil_value: nil,
          empty_value: "",
          strip: @parse_options[:strip] || false,
          fields_converter: build_fields_converter,
          header_fields_converter:
            FieldsConverter.new(nil_value: nil,
                                empty_value: "",
                                accept_nil: true,
                                builtin_converters_name: :HeaderConverters),
        }
        Parser.new(io, options)
      end

      def row_separator_fit(prefix, requested, resolved, rows = nil)
        explicit = requested == :auto ? resolved : requested.to_s.b
        occurrences = prefix.b.scan(Regexp.new(Regexp.escape(explicit))).size
        ends = prefix.b.end_with?(explicit)
        {
          separator: explicit,
          occurrences: occurrences,
          ends: ends,
          embedded_line_breaks: embedded_line_breaks(rows, explicit),
        }
      end

      def embedded_line_breaks(rows, chosen_separator)
        others = ["\r\n".b, "\r".b, "\n".b] - [chosen_separator]
        return 0 if rows.nil?
        rows.sum do |row|
          Array(row).sum do |field|
            next 0 unless field.is_a?(String)
            others.sum {|break_char| field.b.count(break_char)}
          end
        end
      end

      def score(rows, quoted_flags = nil, row_fit = nil)
        data_rows = rows.reject {|row| row.nil? || row.empty?}
        counts = data_rows.collect {|row| row.is_a?(Array) ? row.size : row.size}
        field_count = counts.first || 0
        consistent = counts.length >= 2 &&
                     counts.all? {|count| count == field_count}
        single_row = counts.length == 1
        separator_count = data_rows.sum {|row| [row.size - 1, 0].max}
        quoted_field_count = (quoted_flags || []).count(true)

        # Quoted fields the parser actually recognized only line up when both
        # the column separator and quote character are right, so this signal
        # dominates raw separator counts (a wrong quote can make data look like
        # extra separators).
        score = quoted_field_count * 30
        score += separator_count * 2
        if row_fit
          score += row_fit[:occurrences] * 3
          score += 4 if row_fit[:ends]
          score -= row_fit[:embedded_line_breaks] * 12
        end
        score += data_rows.size
        if consistent
          score += field_count + (field_count - 1) * 4
        elsif single_row
          score += field_count
        else
          score -= data_rows.size * 3
        end
        {
          score: score,
          consistent: consistent || single_row,
          field_count: field_count,
          data_row_count: data_rows.size,
          separator_count: separator_count,
          quoted_field_count: quoted_field_count,
        }
      end

      def confidence(metrics, reasons)
        if metrics[:field_count] <= 1
          :ambiguous
        elsif metrics[:consistent] && metrics[:separator_count] > 0 &&
              metrics[:data_row_count] >= 2
          reasons.any? ? :likely : :high
        elsif metrics[:field_count] >= 2
          :likely
        else
          :low
        end
      end

      def build_evidence(sample, prefix, parser, rows, reasons,
                         quote_character, column_separator, row_fit = nil)
        data_rows = rows.reject {|row| row.nil? || row.empty?}
        quoted = (@quoted_recorder || []).count(true)
        {
          sample_bytes: sample.bytesize,
          evaluated_bytes: prefix.bytesize,
          rows_parsed: rows.size,
          data_row_count: data_rows.size,
          field_counts: data_rows.collect(&:size),
          separator_count: column_separator.to_s.b.empty? ? 0 :
                           sample.b.count(column_separator.to_s.b),
          quote_count: quoted,
          quote_used: quoted.positive?,
          resolved_row_separator: parser.row_separator,
          row_separator_occurrences: row_fit && row_fit[:occurrences],
          row_separator_ends_sample: row_fit && row_fit[:ends],
          incomplete_reasons: reasons,
        }
      end

      def empty_candidate(row_separator, column_separator, quote_character,
                          resolved, sample, reasons)
        Candidate.new(
          row_separator: row_separator,
          column_separator: column_separator,
          quote_character: quote_character,
          resolved_row_separator: resolved,
          status: :empty,
          score: 0,
          confidence: :none,
          consistent: false,
          field_count: 0,
          data_row_count: 0,
          separator_count: 0,
          incomplete: reasons.any?,
          incomplete_reasons: reasons,
          error: nil,
          evidence: {sample_bytes: sample.bytesize, evaluated_bytes: 0,
                     incomplete_reasons: reasons},
          rows: [],
        )
      end

      def truncated_candidate(error, reason, reasons, sample, prefix, parser,
                              row_separator, column_separator, quote_character,
                              rows)
        all_reasons = (reasons + [reason]).uniq
        Candidate.new(
          row_separator: row_separator,
          column_separator: column_separator,
          quote_character: quote_character,
          resolved_row_separator: parser.row_separator,
          status: :incomplete,
          score: 0,
          confidence: :none,
          consistent: false,
          field_count: 0,
          data_row_count: rows.reject {|row| row.nil? || row.empty?}.size,
          separator_count: 0,
          incomplete: true,
          incomplete_reasons: all_reasons,
          error: error.message,
          evidence: build_evidence(sample, prefix, parser, rows, all_reasons,
                                   quote_character, column_separator),
          rows: rows,
        )
      end

      def invalid_candidate(error, sample, prefix, parser,
                            row_separator, column_separator, quote_character,
                            reasons, rows)
        Candidate.new(
          row_separator: row_separator,
          column_separator: column_separator,
          quote_character: quote_character,
          resolved_row_separator: parser.row_separator,
          status: :invalid,
          score: -1,
          confidence: :none,
          consistent: false,
          field_count: 0,
          data_row_count: rows.size,
          separator_count: 0,
          incomplete: false,
          incomplete_reasons: reasons,
          error: error.message,
          evidence: build_evidence(sample, prefix, parser, rows, reasons,
                                   quote_character, column_separator),
          rows: rows,
        )
      end

      def encoding_candidate(sample, prefix, parser,
                             row_separator, column_separator, quote_character,
                             reasons, rows)
        Candidate.new(
          row_separator: row_separator,
          column_separator: column_separator,
          quote_character: quote_character,
          resolved_row_separator: parser.row_separator,
          status: :invalid_encoding,
          score: -1,
          confidence: :none,
          consistent: false,
          field_count: 0,
          data_row_count: rows.size,
          separator_count: 0,
          incomplete: reasons.any?,
          incomplete_reasons: reasons,
          error: "invalid byte sequence in #{@encoding}",
          evidence: build_evidence(sample, prefix, parser, rows, reasons,
                                   quote_character, column_separator),
          rows: rows,
        )
      end
    end
  end
end
