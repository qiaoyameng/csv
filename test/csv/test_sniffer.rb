# frozen_string_literal: false

require_relative "helper"

class TestCSVSniffer < Test::Unit::TestCase
  def sniff(input, **options)
    CSV.sniff(input, **options)
  end

  def test_detects_comma
    result = sniff("a,b,c\n1,2,3\n4,5,6\n")
    assert_equal(",", result.delimiter)
    assert_false(result.ambiguous?)
    assert_false(result.incomplete?)
  end

  def test_detects_semicolon
    result = sniff("name;age\n\"Alice\";30\nBob;25\n")
    assert_equal(";", result.delimiter)
  end

  def test_detects_tab
    result = sniff("a\tb\n1\t2\n")
    assert_equal("\t", result.delimiter)
  end

  def test_detects_pipe_with_custom_candidates
    result = sniff("a|b|c\n1|2|3\n", col_seps: ["|", ","])
    assert_equal("|", result.delimiter)
  end

  def test_respects_caller_candidate_list
    result = sniff("a,b\n1,2\n", col_seps: [";", "\t"])
    assert_nil(result.delimiter)
    assert(result.ambiguous?)
    assert_equal(["\t", ";"], result.candidates.map(&:col_sep).uniq.sort)
  end

  def test_returns_ranked_candidates_with_evidence
    result = sniff("a,b\n1,2\n")
    best = result.candidates.first
    assert_equal(",", best.col_sep)
    assert_equal(2, best.evidence[:rows])
    assert_equal([2, 2], best.evidence[:field_counts])
    assert_equal(2, best.evidence[:fields])
    assert_true(best.consistent?)
    assert_empty(best.errors)
    scores = result.candidates.map(&:score)
    assert_equal(scores.sort.reverse, scores)
  end

  def test_single_column_file_is_ambiguous
    result = sniff("a\nb\nc\n")
    assert_nil(result.delimiter)
    assert(result.ambiguous?)
    assert(result.candidates.size > 1)
  end

  def test_empty_file_is_ambiguous
    result = sniff("")
    assert_nil(result.delimiter)
    assert(result.ambiguous?)
    assert_true(result.empty?)
  end

  def test_comment_only_file_is_ambiguous
    result = sniff("# hello\n# world\n")
    assert_nil(result.delimiter)
    assert(result.ambiguous?)
  end

  def test_comment_lines_do_not_force_comma
    result = sniff("# generated\na;b;c\n1;2;3\n")
    assert_equal(";", result.delimiter)
    best = result.best
    assert_equal(2, best.evidence[:rows])
  end

  def test_comment_option_can_be_disabled
    result = sniff("# a;# b\n1;2\n", comment: nil)
    assert_equal(";", result.delimiter)
    assert_equal(2, result.best.evidence[:rows])
  end

  def test_tie_returns_ambiguity
    result = sniff("a;b,c\n1;2,3\n")
    assert_nil(result.delimiter)
    assert(result.ambiguous?)
    top_scores = result.candidates.map(&:score).uniq
    assert_equal(1, result.candidates.first(2).map(&:score).uniq.size)
    assert_equal(2, top_scores.size)
  end

  def test_truncated_mid_quote_is_incomplete_not_error
    data = "name,note\nAlice,\"hello world, goodbye\"\nBob,\"x\"\n"
    result = sniff(data, sample_size: 20)
    assert_equal(",", result.delimiter)
    assert_true(result.incomplete?)
    best = result.best
    assert_true(best.incomplete?)
    assert_empty(best.errors)
  end

  def test_truncated_mid_multibyte_character
    data = "nom;ville\nLéon;Paris\nMünchen;Berlin\n"
    cut = "nom;ville\nLéon;Paris\nM".bytesize + 1
    sample = data.byteslice(0, cut)
    assert_false(sample.valid_encoding?)
    result = sniff(sample)
    assert_true(result.incomplete?)
    assert_false(result.sample.valid_encoding?)
  end

  def test_same_file_at_every_sample_boundary
    data = "id,name,note\n1,\"Alice, A\",x\n2,Bob,y\n3,Carol,z\n"
    (1..data.bytesize).each do |size|
      result = sniff(data, sample_size: size)
      assert_include([nil, ","], result.delimiter, "sample_size=#{size}")
    end
    full = sniff(data, sample_size: data.bytesize)
    assert_equal(",", full.delimiter)
  end

  def test_same_file_with_quotes_at_boundaries
    data = "a;b\n\"x;y\";2\n3;4\n"
    saw_incomplete = false
    (1..data.bytesize).each do |size|
      result = sniff(data, sample_size: size)
      assert_include([nil, ";"], result.delimiter, "sample_size=#{size}")
      saw_incomplete ||= result.incomplete?
    end
    assert_true(saw_incomplete)
  end

  def test_non_seekable_input_gets_replay_reader
    reader, writer = IO.pipe
    writer.write("a\tb\n1\t2\n")
    writer.close
    result = sniff(reader)
    assert_equal("\t", result.delimiter)
    assert_instance_of(CSV::Sniffer::ReplayReader, result.reader)
    rows = CSV.parse(result.reader, col_sep: result.delimiter).to_a
    assert_equal([["a", "b"], ["1", "2"]], rows)
  end

  def test_replay_reader_does_not_reread_source_bytes
    source = Class.new do
      attr_reader :chunks
      def initialize(data)
        @io = StringIO.new(data)
        @chunks = []
      end

      def read(length)
        chunk = @io.read(length)
        @chunks << chunk if chunk
        chunk
      end
    end
    data = "x,y\n1,2\n3,4\n"
    io = source.new(data)
    result = sniff(io, sample_size: 4)
    assert_equal(",", result.delimiter)
    rest = result.reader.read
    assert_equal(data, rest)
    total = io.chunks.join
    assert_equal(data, total)
  end

  def test_replay_reader_gets_with_separator_and_limit
    io = Class.new do
      def initialize(data)
        @io = StringIO.new(data)
      end

      def read(length)
        @io.read(length)
      end
    end.new("aa,bb,cc,dd")
    result = sniff(io, sample_size: 3)
    reader = result.reader
    assert_equal("aa,", reader.gets(","))
    assert_equal("bb", reader.gets(nil, 2))
    assert_equal(",", reader.gets(",", 3))
    assert_equal("cc,", reader.gets(","))
    assert_equal("dd", reader.gets(","))
    assert_nil(reader.gets(","))
    assert_true(reader.eof?)
  end

  def test_seekable_input_is_rewound
    io = StringIO.new("a,b\n1,2\n")
    result = sniff(io)
    assert_equal(",", result.delimiter)
    assert_same(io, result.reader)
    assert_equal(0, io.pos)
    assert_equal([["a", "b"], ["1", "2"]],
                 CSV.parse(result.reader, col_sep: result.delimiter).to_a)
  end

  def test_string_input_reader_replays_from_start
    result = sniff("a,b\n1,2\n")
    assert_equal([["a", "b"], ["1", "2"]],
                 CSV.parse(result.reader, col_sep: result.delimiter).to_a)
  end

  def test_crlf_file
    result = sniff("a,b\r\n1,2\r\n")
    assert_equal(",", result.delimiter)
  end

  def test_explicit_row_sep_candidates
    result = sniff("a;b\r\n1;2\r\n", row_seps: ["\r\n", :auto])
    assert_equal(";", result.delimiter)
    assert(result.candidates.any? {|c| c.row_sep == "\r\n" })
  end

  def test_custom_quote_char
    result = sniff("a;b\n'x;y';2\n", quote_char: "'")
    assert_equal(";", result.delimiter)
  end

  def test_result_to_h
    result = sniff("a,b\n1,2\n")
    hash = result.to_h
    assert_equal(",", hash[:delimiter])
    assert_false(hash[:ambiguous])
    assert_kind_of(Array, hash[:candidates])
    assert_equal(",", hash[:candidates].first[:col_sep])
  end
end
