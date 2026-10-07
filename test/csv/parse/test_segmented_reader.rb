# frozen_string_literal: true

require_relative "../helper"

class TestCSVSegmentedReader < Test::Unit::TestCase
  extend DifferentOFS

  MARKER = ->(record) { record == ["---"] }

  def setup
    super
  end

  def segmented(data, **options, &block)
    if block
      CSV::SegmentedReader.new(data, **options, &block)
    else
      marker = options.fetch(:segment_marker, MARKER)
      options.delete(:segment_marker)
      CSV::SegmentedReader.new(data, segment_marker: marker, **options)
    end
  end

  def rows(data, **options, &block)
    segmented(data, **options, &(block || MARKER)).map do |row|
      [row.segment_number, row.segment_lineno, row.global_lineno, row.fields]
    end
  end

  def test_two_segments_different_column_order_switch
    data = <<~CSV
      a,b
      1,2
      ---
      b,a
      3,4
    CSV
    reader = segmented(data)

    segments = reader.each_segment.map do |segment|
      {
        number: segment.number,
        marker_lineno: segment.marker_lineno,
        header_lineno: segment.header_lineno,
        headers: segment.headers,
        rows: segment.map { |row| [row.segment_lineno, row.global_lineno, row.to_h] },
      }
    end

    assert_equal(
      [
        {
          number: 1, marker_lineno: nil, header_lineno: 1,
          headers: %w[a b],
          rows: [[1, 2, {"a" => "1", "b" => "2"}]],
        },
        {
          number: 2, marker_lineno: 3, header_lineno: 4,
          headers: %w[b a],
          rows: [[1, 5, {"b" => "3", "a" => "4"}]],
        },
      ],
      segments)
  end

  def test_marker_inside_quoted_multiline_field_is_ignored
    data = "a,b\n\"1\n---\n2\",x\n---\nb,a\n3,4\n"
    result = segmented(data).map do |row|
      [row.segment_number, row.global_lineno, row.to_h]
    end
    assert_equal(
      [
        [1, 2, {"a" => "1\n---\n2", "b" => "x"}],
        [2, 5, {"b" => "3", "a" => "4"}],
      ],
      result)
  end

  def test_marker_only_recognized_on_complete_record_boundary
    # The marker text embedded in another field (same line) never matches.
    data = "id,note\n1,\"---,tail\"\n2,plain\n---\nhdr\nv\n"
    result = segmented(data).map { |row| [row.segment_number, row.global_lineno] }
    assert_equal([[1, 2], [1, 3], [2, 6]], result)
  end

  def test_header_and_field_converters_are_rebuilt_per_segment
    data = "Name,Value\na,10\n---\nValue,Name\n20,b\n"
    reader = segmented(data,
                       header_converters: :symbol,
                       converters: :numeric)
    mapped = reader.map do |row|
      [row.segment_number, row.headers, row.fields]
    end
    assert_equal(
      [
        [1, [:name, :value], ["a", 10]],
        [2, [:value, :name], [20, "b"]],
      ],
      mapped)
  end

  def test_repeated_headers_are_kept_by_position
    data = "x,x,y\n1,2,3\n"
    segment = nil
    segmented(data).each_segment do |found|
      segment = found
      break
    end
    assert_equal(%w[x x y], segment.headers)
    row = segment.shift
    assert_equal([["x", "1"], ["x", "2"], ["y", "3"]], row.to_a)
    assert_equal("1", row.field("x"))
    assert_equal("2", row.field("x", 1))
  end

  def test_unified_output_columns_fill_missing_with_sentinel
    data = "a,b\n1,2\n---\na,c\n3,4\n"
    reader = segmented(data, output_columns: %w[a b c])
    collected = reader.map(&:fields)
    missing = CSV::MissingValue.instance
    assert_equal(
      [
        ["1", "2", missing],
        ["3", missing, "4"],
      ],
      collected)
  end

  def test_missing_sentinel_distinct_from_nil_and_empty_string
    data = "a,b,c\n1,,3\n"
    reader = segmented(data, output_columns: %w[a b c d])
    row = reader.shift
    assert_equal("1", row["a"])
    assert_nil(row["b"])              # blank trailing-style field -> nil
    assert_equal("3", row["c"])
    assert_same(CSV::MissingValue.instance, row["d"])
    assert_not_equal(nil, CSV::MissingValue.instance)
    assert_not_equal("", CSV::MissingValue.instance)
  end

  def test_quoted_empty_field_distinct_from_missing_sentinel
    # A quoted empty field parses to "", never to the missing sentinel.
    data = "a,b,c\n1,\"\",3\n"
    reader = segmented(data, output_columns: %w[a b c d])
    values = reader.shift.fields
    assert_equal("1", values[0])
    assert_equal("", values[1])
    assert_equal("3", values[2])
    assert_same(CSV::MissingValue.instance, values[3])
  end

  def test_custom_missing_value
    reader = segmented("a\n1", output_columns: %w[a z], missing_value: :NA)
    assert_equal(["1", :NA], reader.shift.fields)
  end

  def test_empty_stream_is_one_empty_segment
    reader = segmented("")
    segments = reader.each_segment.to_a
    assert_equal(1, segments.size)
    assert_equal(1, segments.first.number)
    assert_equal(true, segments.first.empty?)
    assert_nil(segments.first.marker_lineno)
  end

  def test_leading_marker_opens_empty_segment
    data = "---\nh\nv\n"
    numbers = []
    segmented(data).each_segment do |segment|
      numbers << [segment.number, segment.empty?, segment.marker_lineno]
    end
    assert_equal([[1, true, 1], [2, false, 1]], numbers)
  end

  def test_consecutive_markers_produce_empty_segments
    data = "---\n---\nh\nv\n"
    result = segmented(data).each_segment.map do |segment|
      [segment.number, segment.empty?, segment.marker_lineno]
    end
    assert_equal([[1, true, 1], [2, true, 1], [3, false, 2]], result)
  end

  def test_trailing_marker_opens_empty_segment
    data = "h\nv\n---\n"
    result = segmented(data).each_segment.map do |segment|
      [segment.number, segment.empty?, segment.headers]
    end
    assert_equal([[1, false, ["h"]], [2, true, nil]], result)
  end

  def test_bad_header_blank_record_raises_missing_header_error
    data = "h\nv\n---\n\nv2\n"
    error = assert_raise(CSV::MissingHeaderError) do
      segmented(data).each_segment.to_a
    end
    assert_equal(2, error.segment.number)
    assert_equal(4, error.line_number)
  end

  def test_blank_header_skipped_when_skip_blanks
    data = "h\nv\n---\n\nx,y\n1,2\n"
    reader = segmented(data, skip_blanks: true)
    segments = reader.each_segment.map { |segment| [segment.number, segment.headers] }
    assert_equal([[1, ["h"]], [2, %w[x y]]], segments)
  end

  def test_partial_segment_iteration_drains_to_next_boundary
    reader = segmented("a\n1\n2\n---\nb\n3\n")
    enumerator = reader.each_segment
    first = enumerator.next
    assert_equal({"a" => "1"}, first.shift.to_h)
    second = enumerator.next
    assert_equal(2, second.number)
    assert_equal({"b" => "3"}, second.shift.to_h)
  end

  def test_regexp_marker_matches_single_field_record
    reader = segmented("a,b\n1,2\n--42--\nx\n9",
                       segment_marker: /\A--\d+--\z/)
    result = reader.map { |row| [row.segment_number, row.to_h] }
    assert_equal(
      [
        [1, {"a" => "1", "b" => "2"}],
        [2, {"x" => "9"}],
      ],
      result)
  end

  def test_block_and_option_marker_are_mutually_exclusive
    assert_raise(ArgumentError) do
      CSV::SegmentedReader.new("x", segment_marker: ["x"]) { |_| true }
    end
  end

  def test_marker_is_required
    assert_raise(ArgumentError) do
      CSV::SegmentedReader.new("x")
    end
  end

  def test_plain_csv_reading_never_treats_content_as_marker
    data = "a,b\n---\nx,y\n1,2\n"
    assert_equal(
      [["a", "b"], ["---"], ["x", "y"], ["1", "2"]],
      CSV.parse(data))
    assert_equal(
      [["a", "b"], ["---"], ["x", "y"], ["1", "2"]],
      CSV.read(StringIO.new(data)))
  end

  def test_reads_from_io
    io = StringIO.new("h\nv\n---\nk\nw\n")
    result = CSV::SegmentedReader.new(io, &MARKER).map do |row|
      [row.segment_number, row.segment_lineno, row.global_lineno, row.to_h]
    end
    assert_equal(
      [
        [1, 1, 2, {"h" => "v"}],
        [2, 1, 5, {"k" => "w"}],
      ],
      result)
  end

  def test_rewind_restarts_segments_and_line_numbers
    reader = segmented("h\nv\n---\nk\nw\n")
    once = reader.map { |row| [row.segment_number, row.global_lineno] }
    reader.rewind
    twice = reader.map { |row| [row.segment_number, row.global_lineno] }
    assert_equal(once, twice)
    assert_equal([[1, 2], [2, 5]], twice)
  end

  def test_segment_lineno_counts_only_data_rows_of_segment
    data = "h\na\nb\n---\nk\nc\nd\n"
    mapping = segmented(data).map do |row|
      [row.segment_number, row.segment_lineno, row.global_lineno]
    end
    assert_equal(
      [
        [1, 1, 2], [1, 2, 3],
        [2, 1, 6], [2, 2, 7],
      ],
      mapping)
  end

  def test_flat_each_and_segments_agree_on_rows
    data = "h\na\n---\nk\nb\nc\n"
    reader1 = segmented(data)
    flat = reader1.map { |row| [row.segment_number, row.fields] }
    reader2 = segmented(data)
    nested = reader2.each_segment.flat_map do |segment|
      segment.map { |row| [row.segment_number, row.fields] }
    end
    assert_equal(nested, flat)
  end

  def test_header_without_data_rows_is_not_empty_but_yields_nothing
    data = "h1\na\n---\nh2\n---\nh3\nz\n"
    found = []
    segmented(data).each_segment do |segment|
      found << [segment.number, segment.headers, segment.empty?, segment.to_a.size]
    end
    assert_equal(
      [
        [1, ["h1"], false, 1],
        [2, ["h2"], false, 0],
        [3, ["h3"], false, 1],
      ],
      found)
  end

  def test_flat_each_yields_rows_from_all_nonempty_segments
    data = "h1\na\n---\n---\nh2\nb\n"
    result = segmented(data).map { |row| [row.segment_number, row.fields] }
    assert_equal([[1, ["a"]], [3, ["b"]]], result)
  end

  def test_ragged_row_extra_fields_are_kept
    data = "a,b\n1,2,3\n"
    row = segmented(data).shift
    assert_equal(%w[1 2 3], row.fields)
  end
end
