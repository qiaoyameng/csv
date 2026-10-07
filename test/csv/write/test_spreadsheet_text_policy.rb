# -*- coding: utf-8 -*-
# frozen_string_literal: false

require_relative "../helper"

module TestCSVWriteSpreadsheetTextPolicy
  def test_disabled_by_default
    assert_equal(%Q[=1+1,foo\n],
                 generate_line(["=1+1", "foo"]))
  end

  def test_disabled_explicitly
    assert_equal(%Q[=1+1\n],
                 generate_line(["=1+1"], spreadsheet_text_policy: nil))
    assert_equal(%Q[=1+1\n],
                 generate_line(["=1+1"], spreadsheet_text_policy: false))
  end

  def test_prefix_formula_leading_characters
    assert_equal(%Q['=1+1,'+1,'-1,'@cmd\n],
                 generate_line(["=1+1", "+1", "-1", "@cmd"],
                               spreadsheet_text_policy: :prefix))
  end

  def test_prefix_distinguishes_numeric_from_string
    assert_equal(%Q[-5,'-5,1.5,'+1.5\n],
                 generate_line([-5, "-5", 1.5, "+1.5"],
                               spreadsheet_text_policy: :prefix))
  end

  def test_prefix_leading_whitespace_and_control_characters
    assert_equal(%Q['  =1+1,'\t+1,"'\r=2","'\n@x", plain\n],
                 generate_line(["  =1+1", "\t+1", "\r=2", "\n@x", " plain"],
                               spreadsheet_text_policy: :prefix))
  end

  def test_prefix_is_not_reapplied
    assert_equal(%Q['=1+1\n],
                 generate_line(["'=1+1"],
                               spreadsheet_text_policy: :prefix))
  end

  def test_prefix_custom_prefix
    assert_equal(%Q[TEXT:=1+1\n],
                 generate_line(["=1+1"],
                               spreadsheet_text_policy: {action: :prefix,
                                                         prefix: "TEXT:"}))
  end

  def test_reject
    error = assert_raise(CSV::SpreadsheetTextError) do
      generate_line(["ok", "=bad"], spreadsheet_text_policy: :reject)
    end
    assert_equal(2, error.column_number)
    assert_equal(1, error.lineno)
    assert_not_include(error.message, "=bad")
  end

  def test_reject_expose_value
    error = assert_raise(CSV::SpreadsheetTextError) do
      generate_line(["ok", "=bad"],
                    spreadsheet_text_policy: {action: :reject,
                                              expose_value: true})
    end
    assert_include(error.message, "=bad")
  end

  def test_force_quotes_does_not_bypass_prefix
    assert_equal(%Q["'=1+1"\n],
                 generate_line(["=1+1"],
                               force_quotes: true,
                               spreadsheet_text_policy: :prefix))
  end

  def test_force_quotes_does_not_bypass_reject
    assert_raise(CSV::SpreadsheetTextError) do
      generate_line(["=1+1"],
                    force_quotes: true,
                    spreadsheet_text_policy: :reject)
    end
  end

  def test_non_utf8_field_encoding_does_not_bypass
    field = "=1+1".encode("Shift_JIS")
    assert_equal("'=1+1\n".encode("Shift_JIS"),
                 generate_line([field], spreadsheet_text_policy: :prefix))
  end

  def test_non_ascii_compatible_field_encoding_does_not_bypass
    field = "=1+1".encode("UTF-16LE")
    output = generate_line([field],
                           encoding: "UTF-16LE",
                           spreadsheet_text_policy: :prefix)
    assert_equal("'=1+1\n", output.encode(Encoding::UTF_8))
    assert_raise(CSV::SpreadsheetTextError) do
      generate_line([field],
                    encoding: "UTF-16LE",
                    spreadsheet_text_policy: :reject)
    end
  end

  def test_write_converters_run_before_policy
    assert_equal(%Q['=a\n],
                 generate_line(["a"],
                               write_converters: ->(value) {"=" + value},
                               spreadsheet_text_policy: :prefix))
  end

  def test_round_trip_shows_changed_fields
    output = generate_line(["=1+1", "plain", "-5"],
                           spreadsheet_text_policy: :prefix)
    assert_equal(["'=1+1", "plain", "'-5"], CSV.parse_line(output))
  end

  def test_invalid_policy
    assert_raise(ArgumentError) do
      generate_line(["a"], spreadsheet_text_policy: :bogus)
    end
  end
end

class TestCSVWriteSpreadsheetTextPolicyGenerateLine < Test::Unit::TestCase
  include TestCSVWriteSpreadsheetTextPolicy
  extend DifferentOFS

  def generate_line(row, **kwargs)
    CSV.generate_line(row, **kwargs)
  end
end

class TestCSVWriteSpreadsheetTextPolicyGenerate < Test::Unit::TestCase
  include TestCSVWriteSpreadsheetTextPolicy
  extend DifferentOFS

  def generate_line(row, **kwargs)
    CSV.generate(**kwargs) do |csv|
      csv << row
    end
  end
end

class TestCSVWriteSpreadsheetTextPolicyHeaders < Test::Unit::TestCase
  extend DifferentOFS

  def generate_with_headers(headers, rows, **kwargs)
    CSV.generate(headers: headers, write_headers: true, **kwargs) do |csv|
      rows.each {|row| csv << row}
    end
  end

  def test_header_row_uses_data_policy_by_default
    output = generate_with_headers(["=name", "val"],
                                   [["=x", 1]],
                                   spreadsheet_text_policy: :prefix)
    assert_equal("'=name,val\n'=x,1\n", output)
  end

  def test_header_policy_only
    output = generate_with_headers(["=name", "val"],
                                   [["=x", 1]],
                                   spreadsheet_header_text_policy: :prefix)
    assert_equal("'=name,val\n=x,1\n", output)
  end

  def test_header_policy_separate_from_data_policy
    output = generate_with_headers(["=name", "val"],
                                   [["=x", 1]],
                                   spreadsheet_text_policy: :prefix,
                                   spreadsheet_header_text_policy: false)
    assert_equal("=name,val\n'=x,1\n", output)
  end

  def test_header_policy_reject
    error = assert_raise(CSV::SpreadsheetTextError) do
      generate_with_headers(["=name", "val"],
                            [],
                            spreadsheet_header_text_policy: :reject)
    end
    assert_equal(1, error.column_number)
    assert_equal(1, error.lineno)
  end

  def test_error_line_number_counts_header_row
    error = assert_raise(CSV::SpreadsheetTextError) do
      generate_with_headers(["name", "val"],
                            [["ok", "=x"]],
                            spreadsheet_text_policy: :reject)
    end
    assert_equal(2, error.column_number)
    assert_equal(2, error.lineno)
  end
end
