# frozen_string_literal: true

require_relative "../helper"

class TestCSVParseRecovery < Test::Unit::TestCase
  include CSVHelper

  def assert_failure(record)
    assert_instance_of(CSV::Failure, record)
    record
  end

  def test_import_returns_rows_and_failures
    data = "good,1\nba\"d,2\nafter,3\n"
    rows, failures = CSV.import(data)
    assert_equal([["good", "1"], ["after", "3"]], rows)
    assert_equal(1, failures.size)
    failure = failures.first
    assert_instance_of(CSV::Failure, failure)
    assert_equal(2, failure.lineno)
    assert_equal("ba\"d,2\n", failure.raw)
    assert_equal(7...14, failure.byte_range)
    assert_equal(false, failure.truncated?)
    assert_match(/Illegal quoting/, failure.reason)
    assert_match(/in line 2\./, failure.reason)
  end

  def test_import_block_form
    data = "good,1\nba\"d,2\nafter,3\n"
    csv = CSV.new(data, recover: true)
    records = csv.to_a
    assert_equal(3, records.size)
    assert_equal(["good", "1"], records[0])
    assert_instance_of(CSV::Failure, records[1])
    assert_equal(["after", "3"], records[2])
    assert_equal(1, csv.failures.size)
  end

  def test_new_with_recover_option
    data = "a,1\nb\"x,2\nc,3\n"
    csv = CSV.new(data, recover: true)
    records = csv.to_a
    assert_equal(3, records.size)
    assert_equal(["a", "1"], records[0])
    assert_instance_of(CSV::Failure, records[1])
    assert_equal(["c", "3"], records[2])
    assert_equal(1, csv.failures.size)
  end

  def test_continues_after_bad_field
    data = "a,1\nb\"x,2\nc,3\nd,4\n"
    rows, failures = CSV.import(data)
    assert_equal([["a", "1"], ["c", "3"], ["d", "4"]], rows)
    assert_equal([2], failures.map(&:lineno))
  end

  def test_multiline_good_record_then_bad_then_good
    data = "\"multi\nline\",1\nba\"d,2\nafter,3\n"
    rows, failures = CSV.import(data)
    assert_equal([["multi\nline", "1"], ["after", "3"]], rows)
    failure = failures.first
    assert_equal(2, failure.lineno)
    assert_equal("ba\"d,2\n", data.byteslice(failure.byte_range))
  end

  def test_newline_inside_legal_quote_is_not_a_boundary
    # The physical newline inside the quoted field must not be used to skip
    # to the next physical line.
    data = "\"a\nb\",1\nba\"d,2\nz,3\n"
    rows, failures = CSV.import(data)
    assert_equal([["a\nb", "1"], ["z", "3"]], rows)
    assert_equal("ba\"d,2\n", data.byteslice(failures.first.byte_range))
  end

  def test_bad_record_containing_multiline_field
    data = "\"multi\nline\",ok,ba\"d\nnext,row\n"
    rows, failures = CSV.import(data)
    assert_equal([["next", "row"]], rows)
    failure = failures.first
    assert_equal(1, failure.lineno)
    assert_equal("\"multi\nline\",ok,ba\"d\n",
                 data.byteslice(failure.byte_range))
  end

  def test_unclosed_quote_is_unrecoverable
    data = "a,b\n\"never closed"
    error = assert_raise(CSV::UnrecoverableMalformedCSVError) do
      CSV.import(data)
    end
    assert_kind_of(CSV::MalformedCSVError, error)
    assert_equal(2, error.line_number)
    assert_equal(4, error.byte_offset)
  end

  def test_unclosed_quote_stops_after_recoverable_failures
    data = "ok,1\nbad\"x,2\n\"oops,no,close\nx,y\n"
    error = assert_raise(CSV::UnrecoverableMalformedCSVError) do
      CSV.import(data)
    end
    assert_equal(3, error.line_number)
    assert_equal(13, error.byte_offset)
  end

  def test_converter_error_only_affects_current_record
    calls = []
    converter = lambda do |field|
      calls << field
      raise "boom" if field == "bad"
      field
    end
    rows, failures = CSV.import("ok\nbad\nafter\n", converters: converter)
    assert_equal([["ok"], ["after"]], rows)
    assert_equal(1, failures.size)
    assert_equal(2, failures.first.lineno)
    assert_equal("bad\n", failures.first.raw)
    # The already parsed successful records are not converted again.
    assert_equal(["ok", "bad", "after"], calls)
  end

  def test_converter_error_multiline_record
    converter = lambda do |field|
      raise "boom" if field == "boom\nx"
      field
    end
    data = "a\n\"boom\nx\"\nz\n"
    rows, failures = CSV.import(data, converters: converter)
    assert_equal([["a"], ["z"]], rows)
    failure = failures.first
    assert_equal(2, failure.lineno)
    assert_equal("\"boom\nx\"\n", data.byteslice(failure.byte_range))
  end

  def test_max_failure_bytes_truncates
    data = ("x" * 50) + "\"bad\ny\nz,9\n"
    rows, failures = CSV.import(data, max_failure_bytes: 10)
    failure = failures.first
    assert_equal(true, failure.truncated?)
    assert_equal(10, failure.raw_bytesize)
    assert_equal("x" * 10, failure.raw)
    # The byte range still covers the whole record.
    assert_operator(failure.byte_range.size, :>, 10)
    assert_equal([["y"], ["z", "9"]], rows)
  end

  def test_max_failure_bytes_nil_keeps_everything
    data = ("x" * 500) + "\"bad\ny\nz,9\n"
    _rows, failures = CSV.import(data, max_failure_bytes: nil)
    failure = failures.first
    assert_equal(false, failure.truncated?)
    assert_equal(data.byteslice(failure.byte_range), failure.raw)
  end

  def test_resync_budget_exceeded_is_unrecoverable
    data = "ok,1\nxy\"" + ("z" * 40) + "\nlater,2\n"
    error = assert_raise(CSV::UnrecoverableMalformedCSVError) do
      CSV.import(data, resync_budget: 10)
    end
    assert_equal(2, error.line_number)
    assert_equal(5, error.byte_offset)
    assert_match(/resync_budget/, error.message)
  end

  def test_no_quote_field_size_is_recoverable
    data = "aaaa\nbb\ncccc\n"
    rows, failures = CSV.import(data,
                                quote_char: nil,
                                max_field_size: 3)
    assert_equal([["bb"]], rows)
    assert_equal([1, 3], failures.map(&:lineno))
    assert_equal("aaaa\n", data.byteslice(failures.first.byte_range))
    assert_match(/Field size exceeded/, failures.first.reason)
  end

  def test_final_record_without_row_sep
    data = "ok,1\nbad\"x,2\nlast,3"
    rows, failures = CSV.import(data)
    assert_equal([["ok", "1"], ["last", "3"]], rows)
    assert_equal("bad\"x,2\n", data.byteslice(failures.first.byte_range))
  end

  def test_headers_mode_returns_csv_row
    data = "h1,h2\nok,1\nbad\"x,2\nafter,3\n"
    rows, failures = CSV.import(data, headers: true)
    assert_equal([{"h1" => "ok", "h2" => "1"},
                  {"h1" => "after", "h2" => "3"}],
                 rows.map(&:to_h))
    assert_equal(3, failures.first.lineno)
  end

  def test_custom_column_separator
    data = "a;b\nx\";1\nz;2\n"
    rows, failures = CSV.import(data, col_sep: ";")
    assert_equal([["a", "b"], ["z", "2"]], rows)
    assert_equal("x\";1\n", data.byteslice(failures.first.byte_range))
  end

  def test_io_input_offsets
    require "stringio"
    data = "good,1\nba\"d,2\nafter,3\n"
    rows, failures = CSV.import(StringIO.new(data))
    assert_equal([["good", "1"], ["after", "3"]], rows)
    assert_equal("ba\"d,2\n", data.byteslice(failures.first.byte_range))
  end

  def test_foreach_with_recover
    require "tempfile"
    path = Tempfile.new("csv_recovery").path
    File.write(path, "a,b\nx\"y,1\nz,2\n")
    records = []
    CSV.foreach(path, recover: true) { |record| records << record }
    assert_equal(3, records.size)
    assert_equal(["a", "b"], records[0])
    assert_instance_of(CSV::Failure, records[1])
    assert_equal(["z", "2"], records[2])
  end

  def test_invalid_options
    assert_raise(ArgumentError) do
      CSV.new("x", max_failure_bytes: -1)
    end
    assert_raise(ArgumentError) do
      CSV.new("x", resync_budget: 0)
    end
  end

  def test_failure_inspect
    _rows, failures = CSV.import("bad\"x\n")
    failure = failures.first
    inspect = failure.inspect
    assert_include(inspect, "CSV::Failure")
    assert_include(inspect, "lineno:1")
  end

  def test_recovery_with_chunked_input
    data = "head1,head2\n" \
           "\"multi\nline\",1\n" \
           "ba\"d,2\n" \
           "\"quoted\nspanning\nchunks\",3\n" \
           "ok,4\n"
    with_chunk_size("3") do
      rows, failures = CSV.import(StringIO.new(data))
      assert_equal([["head1", "head2"],
                    ["multi\nline", "1"],
                    ["quoted\nspanning\nchunks", "3"],
                    ["ok", "4"]],
                   rows)
      failure = failures.first
      assert_equal(3, failure.lineno)
      assert_equal("ba\"d,2\n", data.byteslice(failure.byte_range))
    end
  end

  def test_without_recover_still_raises_and_continues
    data = "aaa,bbb\ndd\"ee.fff\nggg,hhh\n"
    csv = CSV.new(data)
    assert_equal(["aaa", "bbb"], csv.shift)
    assert_raise(CSV::MalformedCSVError) { csv.shift }
    assert_equal(["ggg", "hhh"], csv.shift)
  end
end
