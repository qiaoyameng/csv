# -*- coding: utf-8 -*-
# frozen_string_literal: true

require "stringio"
require_relative "helper"

class TestCSVSniff < Test::Unit::TestCase
  extend DifferentOFS
  include CSVHelper

  def setup
    @comma = "a,b,c\n1,2,3\n4,5,6\n"
    @semicolon = "a;b;c\n1;2;3\n4;5;6\n"
    @tab = "a\tb\tc\n1\t2\t3\n4\t5\t6\n"
  end

  def test_detects_comma
    result = CSV.sniff(@comma)
    assert_equal(",", result.col_sep)
    assert_not_predicate(result, :ambiguous?)
    assert_equal("\n", result.row_sep)
  end

  def test_detects_semicolon
    result = CSV.sniff(@semicolon, col_seps: [",", ";", "\t"])
    assert_equal(";", result.col_sep)
    assert_not_predicate(result, :ambiguous?)
  end

  def test_detects_tab
    result = CSV.sniff(@tab)
    assert_equal("\t", result.col_sep)
  end

  def test_candidates_are_ranked_with_evidence
    result = CSV.sniff(@comma)
    assert_kind_of(CSV::Sniffing::Candidate, result.best)
    assert_equal(",", result.best.column_separator)
    assert(result.candidates.all? {|candidate| candidate.evidence.key?(:sample_bytes)})
    assert(result.candidates.all? {|candidate| candidate.evidence.key?(:field_counts)})
    assert_operator(result.best.score, :>, result.candidates.last.score)
  end

  def test_crlf_and_cr
    assert_equal("\r\n", CSV.sniff("a,b\r\n1,2\r\n3,4\r\n").row_sep)
    assert_equal("\r", CSV.sniff("a,b\r1,2\r3,4\r").row_sep)
  end

  def test_explicit_row_separator_candidates
    result = CSV.sniff("a,b\r\n1,2\r\n", row_seps: ["\r\n", "\n"])
    assert_equal("\r\n", result.row_sep)
  end

  def test_single_column_is_ambiguous_and_does_not_force_comma
    result = CSV.sniff("alpha\nbeta\ngamma\n")
    assert_predicate(result, :ambiguous?)
    assert_nil(result.decision)
    assert_nil(result.col_sep)
    assert_equal(:single_column, result.ambiguity_reason)
    assert_predicate(result, :single_column?)
  end

  def test_empty_input_is_ambiguous
    result = CSV.sniff("")
    assert_predicate(result, :ambiguous?)
    assert_predicate(result, :empty?)
    assert_nil(result.col_sep)
    assert_equal(:empty, result.ambiguity_reason)
  end

  def test_comment_only_input_does_not_force_comma
    result = CSV.sniff("# one, two, three\n# four, five\n",
                       skip_lines: /\A#/)
    assert_predicate(result, :ambiguous?)
    assert_nil(result.col_sep)
  end

  def test_comments_are_skipped_when_real_data_is_tsv
    result = CSV.sniff("# head, with, commas\nx;y\n1;2\n3;4\n",
                       col_seps: [",", ";"],
                       skip_lines: /\A#/)
    assert_equal(";", result.col_sep)
  end

  def test_tie_between_separators_is_ambiguous
    result = CSV.sniff("a,b;c\n1,2;3\n", col_seps: [",", ";"])
    assert_predicate(result, :ambiguous?)
    assert_equal(:indistinguishable_tie, result.ambiguity_reason)
    assert_equal([",", ";"], result.tied.map(&:column_separator).sort)
    assert_nil(result.col_sep)
  end

  def test_caller_chooses_after_ambiguity
    result = CSV.sniff("a,b;c\n1,2;3\n", col_seps: [",", ";"])
    assert_equal([["a,b", "c"], ["1,2", "3"]],
                 result.parse(col_sep: ";"))
    assert_equal([["a", "b;c"], ["1", "2;3"]],
                 result.parse(col_sep: ","))
  end

  def test_quoted_fields_select_correct_quote_and_separator
    data = "\"x,y\",z\n\"a,b\",c\n\"d,e\",f\n"
    result = CSV.sniff(data)
    assert_equal(",", result.col_sep)
    assert_equal("\"", result.quote_char)
    assert_equal([["x,y", "z"], ["a,b", "c"], ["d,e", "f"]],
                 result.reader.read)
  end

  def test_single_quote_candidate
    data = "'a,b','c'\n'x','y,z'\n'p','q'\n"
    result = CSV.sniff(data, quote_chars: ['"', "'"])
    assert_equal(",", result.col_sep)
    assert_equal("'", result.quote_char)
  end

  def test_quote_char_is_inconclusive_when_unused
    result = CSV.sniff("a,b\n1,2\n3,4\n", quote_chars: ['"', "'"])
    assert_equal(",", result.col_sep)
    assert_nil(result.quote_char)
    assert_predicate(result, :quote_inconclusive?)
  end

  def test_quote_boundary_is_incomplete_not_wrong
    data = "a,b\n\"x,y"
    # The bound cuts inside the quoted field; this is incomplete, not a wrong
    # candidate.
    result = CSV.sniff(StringIO.new(data), sample_bytes: 5)
    assert_include(result.incomplete_reasons, :quote_boundary)
    assert_equal(",", result.col_sep)
  end

  def test_unclosed_quote_at_eof_is_invalid
    data = "a,b\n\"x,y"
    result = CSV.sniff(data)
    candidate = result.candidates.find do |c|
      c.column_separator == "," && c.quote_character == "\""
    end
    assert_equal(:invalid, candidate.status)
    assert_match(/Unclosed quoted field/, candidate.error)
  end

  def test_record_boundary_is_incomplete
    result = CSV.sniff(StringIO.new("a,b\n1,2\n3,4"), sample_bytes: 10)
    assert_include(result.incomplete_reasons, :record_boundary)
    assert_equal(",", result.col_sep)
  end

  def test_multibyte_boundary_is_incomplete
    data = "a,b\nc,d\u00e9\nx,y\n"
    cut = data.byteslice(0, data.index("\u00e9")).bytesize + 1
    io = StringIO.new(data)
    result = CSV.sniff(io, sample_bytes: cut, encoding: "UTF-8")
    assert_include(result.incomplete_reasons, :multibyte_boundary)
    assert_equal(",", result.col_sep)
  end

  def test_illegal_quoting_marks_candidate_invalid
    result = CSV.sniff("a,b\na\"b,c\nd,e\n")
    candidate = result.candidates.find do |c|
      c.column_separator == "," && c.quote_character == "\""
    end
    assert_equal(:invalid, candidate.status)
    assert_match(/Illegal quoting/, candidate.error)
  end

  def test_stable_across_sample_boundaries
    data = "id,name,note\n1,alice,hi\n2,bob,\"q, x\"\n3,carol,z\n"
    first_newline = data.index("\n") + 1
    (first_newline...data.bytesize).each do |cut|
      result = CSV.sniff(StringIO.new(data), sample_bytes: cut)
      assert_equal(",", result.col_sep,
                   "expected comma at cut #{cut}")
    end
  end

  def test_reader_from_string_keeps_head
    result = CSV.sniff(@comma, sample_bytes: 4)
    rows = result.reader.read
    assert_equal([%w[a b c], %w[1 2 3], %w[4 5 6]], rows)
  end

  def test_nonseekable_reader_replays_sampled_bytes
    data = "h1,h2,h3\nr1,r2,r3\nr4,r5,r6\n"
    reader, writer = IO.pipe
    Thread.new { writer.write(data); writer.close }
    result = CSV.sniff(reader, sample_bytes: 6)
    assert_equal([%w[h1 h2 h3], %w[r1 r2 r3], %w[r4 r5 r6]],
                 result.reader.read)
  end

  def test_nonseekable_bytes_are_read_once_and_in_order
    source = RecordingIO.new("h1,h2\nr1,r2\nr3,r4\n")
    result = CSV.sniff(source, sample_bytes: 5)
    assert_equal([%w[h1 h2], %w[r1 r2], %w[r3 r4]],
                 result.reader.read)
    expected = 0
    source.reads.each do |position, chunk|
      assert_equal(expected, position)
      expected += chunk.bytesize
    end
    assert_equal(source.data.bytesize, expected)
  end

  def test_nonseekable_multibyte_replay
    data = "aa\u00e9bb,cc\n11\u00e9,22\n"
    reader, writer = IO.pipe
    Thread.new { writer.write(data.b); writer.close }
    result = CSV.sniff(reader, sample_bytes: 3, encoding: "UTF-8")
    assert_equal([["aa\u00e9bb", "cc"], ["11\u00e9", "22"]],
                 result.parse(col_sep: ","))
  end

  def test_seekable_io_does_not_reread_sampled_bytes
    require "tempfile"
    data = "a,b,c\n1,2,3\n4,5,6\n"
    Tempfile.create(["sniff", ".csv"], binmode: true) do |file|
      file.write(data)
      file.flush
      file.rewind
      result = CSV.sniff(file, sample_bytes: 4)
      assert_equal([%w[a b c], %w[1 2 3], %w[4 5 6]],
                   result.reader.read)
    end
  end

  def test_parse_with_block
    result = CSV.sniff(@comma, sample_bytes: 5)
    collected = []
    result.parse {|row| collected << row }
    assert_equal([%w[a b c], %w[1 2 3], %w[4 5 6]], collected)
  end

  def test_headers_forwarded_to_reader
    result = CSV.sniff("h1,h2\nv1,v2\nv3,v4\n", headers: true)
    table = result.reader.read
    assert_equal(["h1", "h2"], table.headers)
    assert_equal({"h1" => "v1", "h2" => "v2"}, table[0].to_h)
  end

  def test_block_form_returns_result
    seen = nil
    returned = CSV.sniff(@comma) {|result| seen = result.col_sep }
    assert_equal(",", seen)
    assert_equal(",", returned.col_sep)
  end

  def test_reader_raises_when_ambiguous
    result = CSV.sniff("alpha\nbeta\n")
    assert_raise(ArgumentError) { result.reader }
  end

  def test_invalid_sample_bytes
    assert_raise(ArgumentError) do
      CSV.sniff(@comma, sample_bytes: 0)
    end
  end

  # Minimal non seekable source: read(n) and eof? only.
  class RecordingIO
    attr_reader :reads, :data

    def initialize(data)
      @data = data.b
      @position = 0
      @reads = []
    end

    def read(length)
      chunk = @data.byteslice(@position, length)
      return nil if chunk.nil? || chunk.empty?
      @reads << [@position, chunk.dup]
      @position += chunk.bytesize
      chunk
    end

    def eof?
      @position >= @data.bytesize
    end

    def external_encoding
      Encoding::UTF_8
    end
  end
end
