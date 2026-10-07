# frozen_string_literal: false

require_relative "../helper"

module TestCSVWriteSpreadsheetTextPolicy
  def test_default_off
    assert_equal(%Q[=1+1,-1,@cmd,#{"\t"}=2#{$INPUT_RECORD_SEPARATOR}],
                 generate_line(["=1+1", "-1", "@cmd", "\t=2"]))
  end

  def test_prefix_formula_characters
    assert_equal(%Q['=1,'+1,'-1,'@1,plain,1#{$INPUT_RECORD_SEPARATOR}],
                 generate_line(["=1", "+1", "-1", "@1", "plain", "1"],
                               spreadsheet_text_policy: :prefix))
  end

  def test_prefix_after_skipped_leading_characters
    assert_equal(%Q[' =1,'#{"\t"}=1,"'#{"\r"}=1", x #{$INPUT_RECORD_SEPARATOR}],
                 generate_line([" =1", "\t=1", "\r=1", " x "],
                               spreadsheet_text_policy: :prefix))
  end

  def test_prefix_distinguishes_numeric_from_string
    assert_equal(%Q[-1,1.5,'-1,'+2#{$INPUT_RECORD_SEPARATOR}],
                 generate_line([-1, 1.5, "-1", "+2"],
                               spreadsheet_text_policy: :prefix))
  end

  def test_prefix_does_not_double_prefix
    assert_equal(%Q['=1#{$INPUT_RECORD_SEPARATOR}],
                 generate_line(["'=1"],
                               spreadsheet_text_policy: :prefix))
  end

  def test_prefix_custom_prefix
    assert_equal(%Q[!=1#{$INPUT_RECORD_SEPARATOR}],
                 generate_line(["=1"],
                               spreadsheet_text_policy: {action: :prefix,
                                                         prefix: "!"}))
  end

  def test_reject
    error = assert_raise(CSV::SpreadsheetTextError) do
      generate_line(["ok", "=1+1"], spreadsheet_text_policy: :reject)
    end
    assert_equal(1, error.line_number)
    assert_equal(1, error.column_number)
    assert_equal("Dangerous spreadsheet text in line 1, column 1.",
                 error.message)
  end

  def test_reject_does_not_echo_value_by_default
    error = assert_raise(CSV::SpreadsheetTextError) do
      generate_line(["=secret"], spreadsheet_text_policy: :reject)
    end
    assert_not_include(error.message, "secret")
  end

  def test_reject_expose_value
    error = assert_raise(CSV::SpreadsheetTextError) do
      generate_line(["=secret"],
                    spreadsheet_text_policy: {action: :reject,
                                              expose_value: true})
    end
    assert_include(error.message, "=secret")
  end

  def test_reject_reports_logical_line_number
    error = assert_raise(CSV::SpreadsheetTextError) do
      CSV.generate(spreadsheet_text_policy: :reject) do |csv|
        csv << ["ok"]
        csv << ["ok", "@cmd"]
      end
    end
    assert_equal(2, error.line_number)
    assert_equal(1, error.column_number)
  end

  def test_force_quotes_does_not_bypass_prefix
    assert_equal(%Q["'=1","plain"#{$INPUT_RECORD_SEPARATOR}],
                 generate_line(["=1", "plain"],
                               force_quotes: true,
                               spreadsheet_text_policy: :prefix))
  end

  def test_force_quotes_does_not_bypass_reject
    assert_raise(CSV::SpreadsheetTextError) do
      generate_line(["=1"],
                    force_quotes: true,
                    spreadsheet_text_policy: :reject)
    end
  end

  def test_field_encoding_does_not_bypass
    # Shift_JIS (ASCII-compatible) field is checked and prefixed.
    assert_equal("'=1\n".encode("Shift_JIS"),
                 generate_line(["=1".encode("Shift_JIS")],
                               spreadsheet_text_policy: :prefix))
    # A UTF-16LE field cannot hide a dangerous leading character: the
    # policy rejects it before any output encoding conversion happens.
    assert_raise(CSV::SpreadsheetTextError) do
      generate_line(["=1".encode("UTF-16LE")],
                    spreadsheet_text_policy: :reject)
    end
    # Prefixing a UTF-16LE field keeps the field's own encoding.
    assert_equal("'=1\n".encode("UTF-16LE"),
                 CSV.generate_line(["=1".encode("UTF-16LE")],
                                   spreadsheet_text_policy: :prefix))
  end

  def test_invalid_bytes_do_not_raise
    field = "=1\xFF".dup.force_encoding("UTF-8")
    assert_equal(%Q['=1\xff#{$INPUT_RECORD_SEPARATOR}].dup.force_encoding("UTF-8"),
                 generate_line([field], spreadsheet_text_policy: :prefix))
  end

  def test_write_converters_run_before_policy
    converter = lambda {|field| field.is_a?(String) ? "=" + field : field }
    assert_raise(CSV::SpreadsheetTextError) do
      generate_line(["plain"],
                    write_converters: converter,
                    spreadsheet_text_policy: :reject)
    end
  end

  def test_header_row_uses_data_policy_by_default
    assert_equal(%Q[=h,v#{$INPUT_RECORD_SEPARATOR}a,1#{$INPUT_RECORD_SEPARATOR}],
                 CSV.generate(headers: ["=h", "v"],
                              write_headers: true,
                              spreadsheet_text_policy: :reject) do |csv|
                   csv << ["a", 1]
                 end)
  end

  def test_header_row_separate_policy
    assert_equal(%Q['=h,v#{$INPUT_RECORD_SEPARATOR}a,1#{$INPUT_RECORD_SEPARATOR}],
                 CSV.generate(headers: ["=h", "v"],
                              write_headers: true,
                              spreadsheet_text_policy: :reject,
                              header_spreadsheet_text_policy: :prefix) do |csv|
                   csv << ["a", 1]
                 end)
  end

  def test_header_row_reject_reports_first_line
    error = assert_raise(CSV::SpreadsheetTextError) do
      CSV.generate(headers: ["ok", "=h"],
                   write_headers: true,
                   header_spreadsheet_text_policy: :reject) do |csv|
        csv << ["a", 1]
      end
    end
    assert_equal(1, error.line_number)
    assert_equal(1, error.column_number)
  end

  def test_read_back_shows_changed_fields
    rows = [["=1+1", "plain", "-1"], ["@cmd", "1", "ok"]]
    output = CSV.generate(spreadsheet_text_policy: :prefix) do |csv|
      rows.each {|row| csv << row }
    end
    read_back = CSV.parse(output)
    changed = []
    rows.each_with_index do |row, i|
      row.each_with_index do |field, j|
        changed << [i, j] unless read_back[i][j] == field
      end
    end
    assert_equal([[0, 0], [0, 2], [1, 0]], changed)
    assert_equal("'=1+1", read_back[0][0])
  end

  def test_invalid_policy
    error = assert_raise(ArgumentError) do
      generate_line(["a"], spreadsheet_text_policy: :nope)
    end
    assert_equal(":spreadsheet_text_policy must be " +
                 ":reject, :prefix, a Hash, or nil: :nope",
                 error.message)
  end

  def test_invalid_action
    error = assert_raise(ArgumentError) do
      generate_line(["a"], spreadsheet_text_policy: {action: :nope})
    end
    assert_equal(":action must be :reject or :prefix: :nope",
                 error.message)
  end

  def test_empty_prefix
    error = assert_raise(ArgumentError) do
      generate_line(["a"], spreadsheet_text_policy: {action: :prefix,
                                                     prefix: ""})
    end
    assert_equal(':prefix must be a non-empty String: ""',
                 error.message)
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
