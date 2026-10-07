# frozen_string_literal: true

require_relative "helper"

class TestCSVSegmentedReader < Test::Unit::TestCase
  def read(data, **options)
    CSV::SegmentedReader.new(data, marker: "##SEG##", **options).read
  end

  def test_segment_switch_with_different_column_order
    rows = read(<<~CSV)
      id,name
      1,alice
      ##SEG##
      name,id
      bob,2
    CSV
    assert_equal(2, rows.size)

    assert_equal([0, 0, 0], [rows[0].segment, rows[0].segment_row, rows[0].global_row])
    assert_equal(%w[id name], rows[0].headers)
    assert_equal(["1", "alice"], [rows[0]["id"], rows[0]["name"]])

    assert_equal([1, 0, 1], [rows[1].segment, rows[1].segment_row, rows[1].global_row])
    assert_equal(%w[name id], rows[1].headers)
    assert_equal(["2", "bob"], [rows[1]["id"], rows[1]["name"]])
  end

  def test_marker_inside_quoted_multiline_field_is_not_a_switch
    rows = read(<<~CSV)
      id,note
      1,"look:
      ##SEG##
      not a switch"
      ##SEG##
      note,id
      done,2
    CSV
    assert_equal(2, rows.size)
    assert_equal(0, rows[0].segment)
    assert_equal("look:\n##SEG##\nnot a switch", rows[0]["note"])
    assert_equal(1, rows[1].segment)
    assert_equal("done", rows[1]["note"])
  end

  def test_marker_callable_receives_raw_record
    seen = []
    marker = lambda do |record|
      seen << record
      record.first == "v2"
    end
    rows = CSV::SegmentedReader.new("a,b\n1,2\nv2,c\nb,a\n3,4\n",
                                    marker: marker).read
    assert_equal([["a", "b"], ["1", "2"], ["v2", "c"], ["b", "a"], ["3", "4"]],
                 seen)
    assert_equal(2, rows.size)
    assert_equal([0, 1], rows.map(&:segment))
    assert_equal(["3", "4"], rows[1].fields)
  end

  def test_row_numbering
    rows = read(<<~CSV)
      h
      a
      b
      ##SEG##
      h
      c
    CSV
    assert_equal([[0, 0, 0], [0, 1, 1], [1, 0, 2]],
                 rows.map {|row| [row.segment, row.segment_row, row.global_row]})
  end

  def test_duplicate_headers_are_kept_positionally
    rows = read(<<~CSV)
      a,b,a
      1,2,3
    CSV
    row = rows.first
    assert_equal(%w[a b a], row.headers)
    assert_equal(%w[1 2 3], row.fields)
    assert_equal([["a", "1"], ["b", "2"], ["a", "3"]], row.to_a)
  end

  def test_unified_columns_reorder_and_fill_missing
    rows = read(<<~CSV, columns: %w[id name tag], missing: :NA)
      id,name
      1,alice
      ##SEG##
      name,id,tag
      bob,2,x
    CSV
    assert_equal([["1", "alice", :NA], ["2", "bob", "x"]],
                 rows.map {|row| [row["id"], row["name"], row["tag"]]})
    assert_equal(%w[id name tag], rows[0].headers)
  end

  def test_missing_marker_is_distinct_from_empty_value
    rows = read(<<~CSV, columns: %w[a b c])
      a,b
      1,""
    CSV
    row = rows.first
    assert_equal("", row["b"])
    assert_same(CSV::SegmentedReader::MISSING, row["c"])
    assert_not_equal("", CSV::SegmentedReader::MISSING)
  end

  def test_unified_columns_with_duplicates_match_by_occurrence
    rows = read(<<~CSV, columns: %w[a a b])
      b,a,a
      1,2,3
    CSV
    assert_equal([["a", "2"], ["a", "3"], ["b", "1"]], rows.first.to_a)
  end

  def test_unknown_column_is_not_silently_dropped
    error = assert_raise(CSV::SegmentedReader::UnknownColumnError) do
      read("a,b\n1,2\n", columns: %w[a])
    end
    assert_include(error.message, "b")
  end

  def test_extra_duplicate_occurrence_is_not_silently_dropped
    assert_raise(CSV::SegmentedReader::UnknownColumnError) do
      read("a,a\n1,2\n", columns: %w[a])
    end
  end

  def test_consecutive_markers_produce_empty_segment
    reader = CSV::SegmentedReader.new("h\nr\n##SEG##\n##SEG##\nh2\nr2\n",
                                      marker: "##SEG##")
    rows = reader.read
    assert_equal([0, 2], rows.map(&:segment))
    segments = reader.segments
    assert_equal(3, segments.size)
    assert_equal([["h"], nil, ["h2"]], segments.map(&:headers))
    assert_equal([1, 0, 1], segments.map(&:row_count))
    assert_predicate(segments[1], :empty?)
  end

  def test_leading_and_trailing_markers_produce_empty_segments
    reader = CSV::SegmentedReader.new("##SEG##\nh\nr\n##SEG##\n",
                                      marker: "##SEG##")
    rows = reader.read
    assert_equal([1], rows.map(&:segment))
    assert_equal([nil, ["h"], nil], reader.segments.map(&:headers))
  end

  def test_empty_stream_has_no_segments
    reader = CSV::SegmentedReader.new("", marker: "##SEG##")
    assert_equal([], reader.read)
    assert_equal([], reader.segments)
  end

  def test_marker_only_stream_has_only_empty_segments
    reader = CSV::SegmentedReader.new("##SEG##\n", marker: "##SEG##")
    assert_equal([], reader.read)
    assert_equal([nil, nil], reader.segments.map(&:headers))
  end

  def test_header_only_segment_is_empty_of_rows
    reader = CSV::SegmentedReader.new("h\n##SEG##\nh2\nr\n", marker: "##SEG##")
    rows = reader.read
    assert_equal([1], rows.map(&:segment))
    assert_equal([["h"], ["h2"]], reader.segments.map(&:headers))
    assert_equal([0, 1], reader.segments.map(&:row_count))
  end

  def test_blank_line_as_header_is_a_bad_header
    assert_raise(CSV::SegmentedReader::BadHeaderError) do
      read("h\nr\n##SEG##\n\nr2\n")
    end
  end

  def test_blank_first_line_is_a_bad_header
    assert_raise(CSV::SegmentedReader::BadHeaderError) do
      read("\nr\n")
    end
  end

  def test_bad_header_error_is_a_malformed_csv_error
    assert_raise_kind_of(CSV::MalformedCSVError) do
      read("\nr\n")
    end
  end

  def test_header_converters_are_applied_per_segment
    rows = read(<<~CSV, header_converters: :symbol)
      id,name
      1,alice
      ##SEG##
      name,id
      bob,2
    CSV
    assert_equal([:id, :name], rows[0].headers)
    assert_equal([:name, :id], rows[1].headers)
    assert_equal("2", rows[1][:id])
  end

  def test_header_converter_runs_for_every_segment
    counts = Hash.new(0)
    numbering = lambda do |header|
      counts[header] += 1
      "#{header}#{counts[header]}"
    end
    rows = read(<<~CSV, header_converters: numbering)
      a
      1
      ##SEG##
      a
      2
    CSV
    assert_equal(["a1"], rows[0].headers)
    assert_equal(["a2"], rows[1].headers)
  end

  def test_field_converters_see_per_segment_headers
    upcase_up = lambda do |field, info|
      info.header == "up" ? field.upcase : field
    end
    rows = read(<<~CSV, converters: upcase_up)
      up,down
      a,b
      ##SEG##
      down,up
      c,d
    CSV
    assert_equal(["A", "b"], rows[0].fields)
    assert_equal(["c", "D"], rows[1].fields)
  end

  def test_builtin_converters
    rows = read(<<~CSV, converters: :integer)
      n
      1
      ##SEG##
      n
      2
    CSV
    assert_equal([1, 2], rows.map {|row| row["n"]})
  end

  def test_marker_is_required
    assert_raise(ArgumentError) do
      CSV::SegmentedReader.new("a\n")
    end
  end

  def test_header_options_are_rejected
    assert_raise(ArgumentError) do
      CSV::SegmentedReader.new("a\n", marker: "m", headers: true)
    end
  end

  def test_plain_csv_treats_marker_lines_as_data
    data = "a,b\n##SEG##\n1,2\n"
    assert_equal([["a", "b"], ["##SEG##"], ["1", "2"]], CSV.parse(data))
    table = CSV.parse(data, headers: true)
    assert_equal("##SEG##", table[0]["a"])
    assert_equal(["1", "2"], table[1].fields)
  end

  def test_io_source
    require "stringio"
    rows = CSV::SegmentedReader.new(StringIO.new("h\nr\n"), marker: "m").read
    assert_equal([["r"]], rows.map(&:fields))
  end

  def test_col_sep_is_passed_through
    rows = read("a;b\n1;2\n", col_sep: ";")
    assert_equal(%w[a b], rows.first.headers)
    assert_equal(%w[1 2], rows.first.fields)
  end
end
