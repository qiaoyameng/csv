# frozen_string_literal: false

require_relative "../helper"

class TestCSVParseRecovery < Test::Unit::TestCase
  def test_good_rows_with_multiline_fields
    data = <<~CSV
      id,name,note
      1,"Ada","first line
      second line"
      2,Bob,simple
    CSV

    rows = []
    CSV.parse(data, recovery: true) { |row| rows << row }

    assert_equal([
                   ["id", "name", "note"],
                   ["1", "Ada", "first line\nsecond line"],
                   ["2", "Bob", "simple"],
                 ],
                 rows)
  end

  def test_bad_field_row_keeps_going_with_raw_bytes_and_lineno
    data = <<~CSV
      a,b,c
      1,"ok","x"bad
      2,next,row
    CSV

    results = CSV.parse(data, recovery: true)

    assert_kind_of(CSV::MalformedRecord, results[1])
    failure = results[1]
    assert_equal(2, failure.lineno)
    assert_equal("1,\"ok\",\"x\"bad\n".bytesize,
                 failure.end_byte - failure.start_byte)
    assert_equal(data.index("1,"), failure.start_byte)
    assert_equal("1,\"ok\",\"x\"bad\n", failure.raw)
    assert_not_predicate(failure, :truncated?)
    assert_predicate(failure, :recoverable?)
    assert_not_predicate(failure, :unrecoverable?)
    assert_match(/Any value after quoted field isn't allowed/,
                 failure.error.message)
    assert_equal(["2", "next", "row"], results[2])
  end

  def test_recovery_does_not_split_on_newline_inside_quoted_field
    data = "1,\"multi\nline\"\n2,\"q\"x\n3,done\n"

    results = CSV.parse(data, recovery: true)

    assert_equal(["1", "multi\nline"], results[0])
    assert_kind_of(CSV::MalformedRecord, results[1])
    assert_equal(data.index("2,"), results[1].start_byte)
    assert_equal("2,\"q\"x\n", results[1].raw)
    assert_equal(["3", "done"], results[2])
  end

  def test_continuation_position_after_bad_record
    data = "a,1\nb,\"q\"junk\nc,3\n"

    failure_seen = false
    next_row = nil
    CSV.parse(data, recovery: true) do |row|
      if row.is_a?(CSV::MalformedRecord)
        failure_seen = true
      elsif failure_seen && next_row.nil?
        next_row = row
      end
    end

    assert(failure_seen)
    assert_equal(["c", "3"], next_row)
  end

  def test_unclosed_quote_at_end_is_unrecoverable_and_stops
    data = "1,ok\n2,\"never closed\n3,would come after\n"

    results = CSV.parse(data, recovery: true)

    assert_equal([["1", "ok"]], results.grep(Array))
    failure = results.last
    assert_kind_of(CSV::UnrecoverableRecord, failure)
    assert_not_predicate(failure, :recoverable?)
    assert_equal(2, failure.lineno)
    assert_equal("2,\"never closed\n3,would come after\n", failure.raw)
    assert_match(/Unclosed quoted field/, failure.error.message)
  end

  def test_unclosed_quote_without_trailing_newline
    data = "1,ok\n2,\"open"

    results = CSV.parse(data, recovery: true)

    assert_equal([["1", "ok"]], results.grep(Array))
    assert_kind_of(CSV::UnrecoverableRecord, results.last)
    assert_equal("2,\"open", results.last.raw)
  end

  def test_converter_error_only_affects_current_record
    converted_lines = []
    converter = lambda do |field, info|
      converted_lines << [field, info.line]
      raise "converter boom" if field == "BAD"
      field
    end
    data = "a,1\nb,BAD\nc,3\n"

    results = CSV.parse(data, recovery: true, converters: [converter])

    assert_equal(["a", "1"], results[0])
    assert_kind_of(CSV::MalformedRecord, results[1])
    assert_match(/converter boom/, results[1].error.message)
    assert_equal("b,BAD\n", results[1].raw)
    assert_equal(["c", "3"], results[2])

    # The converter must run exactly once per field; earlier successful
    # records are not converted again.
     assert_equal([
                   ["a", 1], ["1", 1],
                   ["b", 2], ["BAD", 2],
                   ["c", 4], ["3", 4],
                 ],
                 converted_lines)
  end

  def test_scan_budget_exceeded_is_unrecoverable
    trailing = ("a" * 40)
    data = "ok,1\nx,\"#{trailing}"

    results = CSV.parse(data,
                        recovery: true,
                        recovery_scan_budget: 10)

    assert_equal([["ok", "1"]], results.grep(Array))
    failure = results.last
    assert_kind_of(CSV::UnrecoverableRecord, failure)
    assert_equal(10, failure.end_byte - failure.start_byte)
  end

  def test_retained_bytes_are_capped_and_marked_truncated
    huge_field = "z" * 100
    data = "h,1\n2,\"q\"#{huge_field}\nt,3\n"

    results = CSV.parse(data,
                        recovery: true,
                        max_retained_bytes: 16)

    failure = results.grep(CSV::MalformedRecord).first
    assert_not_nil(failure)
    assert_equal(16, failure.raw.bytesize)
    assert_predicate(failure, :truncated?)
    full_size = failure.end_byte - failure.start_byte
    assert_equal(full_size, failure.raw_bytesize)
    assert(full_size > 16)
    assert_equal(["t", "3"], results.last)
  end

  def test_recovery_disabled_raises_as_before
    data = "1,\"ok\",\"x\"bad\n2,next\n"

    assert_raise(CSV::MalformedCSVError) do
      CSV.parse(data)
    end
  end

  def test_non_block_parse_returns_failures_alongside_rows
    data = "a,1\nb,\"q\"junk\nc,3\n"

    results = CSV.parse(data, recovery: true)

    assert_equal(3, results.size)
    assert_equal(["a", "1"], results[0])
    assert_kind_of(CSV::MalformedRecord, results[1])
    assert_equal(["c", "3"], results[2])
  end

  def test_invalid_byte_sequence_is_unrecoverable
    data = "ok,1\nbad,\xFF\nafter,2\n".dup.force_encoding("UTF-8")

    results = CSV.parse(data, recovery: true)

    failure = results.grep(CSV::MalformedRecord).first
    assert_not_nil(failure)
    assert_kind_of(CSV::UnrecoverableRecord, failure)
  end

  def test_recovery_with_file_io
    Tempfile.create(["csv-recovery", ".csv"]) do |file|
      file.binmode
      file.write("1,ok\n2,\"q\"bad\n3,fine\n")
      file.flush
      file.rewind

      results = CSV.read(file.path, recovery: true)
      assert_equal(["1", "ok"], results[0])
      assert_kind_of(CSV::MalformedRecord, results[1])
      assert_equal("2,\"q\"bad\n", results[1].raw)
      assert_equal(["3", "fine"], results[2])
    end
  end

  def test_recovery_with_crlf_row_separator
    data = "1,ok\r\n2,\"q\"x\r\n3,fine\r\n"

    results = CSV.parse(data, recovery: true)

    assert_equal(["1", "ok"], results[0])
    assert_kind_of(CSV::MalformedRecord, results[1])
    assert_equal("2,\"q\"x\r\n", results[1].raw)
    assert_equal(["3", "fine"], results[2])
  end

  def test_headers_mode_with_bad_data_row
    data = "name,value\ngood,1\nbad,\"q\"junk\nnext,2\n"

    results = CSV.parse(data, headers: true, recovery: true)

    assert_kind_of(CSV::Row, results[0])
    assert_equal("good", results[0]["name"])
    assert_kind_of(CSV::MalformedRecord, results[1])
    assert_equal("next", results[2]["name"])
  end

  def test_bad_header_is_unrecoverable_and_stops
    data = "h1,h2\n1,2\n3,4\n"
    seen = []
    CSV.parse(data,
              recovery: true,
              headers: true,
              return_headers: true,
              header_converters: [->(header) { raise "header boom" }]) do |item|
      seen << item
    end

    assert_equal(1, seen.size)
    assert_kind_of(CSV::UnrecoverableRecord, seen.first)
    assert_match(/header boom/, seen.first.error.message)
  end

  def test_field_size_limit_is_recoverable
    data = "ok,1\nabcdef,2\nx,3\n"

    results = CSV.parse(data, recovery: true, max_field_size: 3)

    assert_equal(["ok", "1"], results[0])
    assert_kind_of(CSV::MalformedRecord, results[1])
    assert_predicate(results[1], :recoverable?)
    assert_match(/Field size exceeded/, results[1].error.message)
    assert_equal("abcdef,2\n", results[1].raw)
    assert_equal(["x", "3"], results[2])
  end

  def test_empty_input
    assert_equal([], CSV.parse("", recovery: true))
  end
end
