# frozen_string_literal: false

require_relative "helper"

class TestCSVTypeAnalyzer < Test::Unit::TestCase
  def analyze(data, **options)
    CSV::TypeAnalyzer.new(**options).analyze(StringIO.new(data))
  end

  def test_integer_column_keeps_numeric_and_string_candidates
    report = analyze("1\n2\n-3\n")
    column = report.columns[0]
    assert_equal(%i[integer decimal string], column.candidates)
    assert_false(column.nullable?)
  end

  def test_decimal_column
    report = analyze("1.5\n2\n-0.25\n")
    assert_equal(%i[decimal string], report.columns[0].candidates)
    assert_equal(:not_an_integer, report.columns[0].exclusions[:integer][:reason])
  end

  def test_iso_date_column
    report = analyze("2024-01-01\n2024-12-31\n")
    assert_equal(%i[date string], report.columns[0].candidates)
  end

  def test_invalid_iso_date_is_excluded_by_later_record
    report = analyze("2024-01-01\n2024-02-30\n")
    column = report.columns[0]
    assert_equal(%i[string], column.candidates)
    assert_equal(:invalid_iso_date, column.exclusions[:date][:reason])
    assert_equal(2, column.exclusions[:date][:examples].first[:record])
  end

  def test_zoned_time_column
    report = analyze("2024-01-01T10:00:00+09:00\n2024-01-02 10:00:00Z\n")
    assert_equal(%i[time string], report.columns[0].candidates)
  end

  def test_time_without_timezone_is_not_a_zoned_time
    report = analyze("2024-01-01T10:00:00\n")
    column = report.columns[0]
    assert_equal(:not_a_zoned_time, column.exclusions[:time][:reason])
    assert_include(column.candidates, :string)
  end

  def test_later_record_overrules_earlier_candidate_and_reason_is_kept
    report = analyze("1\n2\nabc\n")
    column = report.columns[0]
    assert_equal(%i[string], column.candidates)
    exclusion = column.exclusions[:integer]
    assert_equal(:not_an_integer, exclusion[:reason])
    assert_equal("abc", exclusion[:examples].first[:value])
    assert_equal(3, exclusion[:examples].first[:record])
  end

  def test_overruling_record_is_replayed
    report = analyze("1\n2\nabc\n4\n", sample_size: 3)
    assert_false(report.eof?)
    assert_equal([["1"], ["2"], ["abc"], ["4"]], report.each.to_a)
  end

  def test_leading_zeros_default_policy_excludes_numeric
    report = analyze("007\n")
    column = report.columns[0]
    assert_equal(%i[string], column.candidates)
    assert_equal(:leading_zeros, column.exclusions[:integer][:reason])
    assert_equal(:leading_zeros, column.exclusions[:decimal][:reason])
  end

  def test_leading_zeros_convert_policy
    report = analyze("007\n", leading_zeros: :convert)
    assert_include(report.columns[0].candidates, :integer)
  end

  def test_large_integer_default_policy_keeps_decimal
    report = analyze("9223372036854775808\n")
    column = report.columns[0]
    assert_equal(%i[decimal string], column.candidates)
    assert_equal(:too_large_integer, column.exclusions[:integer][:reason])
  end

  def test_large_integer_integer_policy
    report = analyze("9223372036854775808\n", large_integer: :integer)
    assert_include(report.columns[0].candidates, :integer)
  end

  def test_large_integer_string_policy
    report = analyze("9223372036854775808\n", large_integer: :string)
    column = report.columns[0]
    assert_equal(%i[string], column.candidates)
    assert_equal(:too_large_integer, column.exclusions[:decimal][:reason])
  end

  def test_empty_unquoted_is_null_by_default
    report = analyze("1,x\n2,\n3,y\n")
    column = report.columns[1]
    assert_true(column.nullable?)
    assert_equal(%i[string], column.candidates)
  end

  def test_empty_unquoted_as_empty_string
    report = analyze("1,2\n2,\n3,4\n", empty_unquoted: :empty_string)
    column = report.columns[1]
    assert_false(column.nullable?)
    assert_equal(%i[string], column.candidates)
  end

  def test_missing_fields_in_short_rows_are_null
    report = analyze("1\n\n2\n")
    assert_true(report.columns[0].nullable?)
  end

  def test_quoted_empty_is_empty_string_by_default
    report = analyze(%(1\n""\n2\n))
    column = report.columns[0]
    assert_false(column.nullable?)
    assert_equal(%i[string], column.candidates)
    assert_equal(:not_an_integer, column.exclusions[:integer][:reason])
  end

  def test_quoted_empty_as_null
    report = analyze(%(1\n""\n2\n), quoted_empty: :null)
    column = report.columns[0]
    assert_true(column.nullable?)
    assert_equal(%i[integer decimal string], column.candidates)
  end

  def test_examples_are_limited_but_count_is_full
    data = (["1"] + ["x"] * 10).join("\n") + "\n"
    report = analyze(data, max_examples: 2)
    exclusion = report.columns[0].exclusions[:integer]
    assert_equal(10, exclusion[:count])
    assert_equal(2, exclusion[:examples].size)
  end

  def test_masked_values
    report = analyze("1\nsecret\n", mask_values: true)
    example = report.columns[0].exclusions[:integer][:examples].first
    assert_equal("<masked:6>", example[:value])
  end

  def test_masked_values_with_callable
    report = analyze("1\nsecret\n", mask_values: ->(value) { value[0] + "..." })
    example = report.columns[0].exclusions[:integer][:examples].first
    assert_equal("s...", example[:value])
  end

  def test_duplicate_headers_are_analyzed_per_position
    report = analyze("a,a\n1,x\n", headers: true)
    assert_equal(2, report.columns.size)
    assert_equal([0, 1], report.columns.map(&:index))
    assert_equal(%w[a a], report.columns.map(&:header))
    assert_include(report.columns[0].candidates, :integer)
    assert_equal(%i[string], report.columns[1].candidates)
  end

  def test_eof_true_when_input_exhausted
    report = analyze("1\n2\n", sample_size: 100)
    assert_true(report.eof?)
    assert_equal(2, report.sampled_rows)
  end

  def test_eof_false_when_sample_limit_hit
    report = analyze("1\n2\n3\n", sample_size: 2)
    assert_false(report.eof?)
    assert_equal(2, report.sampled_rows)
  end

  def test_replay_reads_sampled_then_remaining_records
    report = analyze("h\n1\n2\n3\n4\n", headers: true, sample_size: 2)
    assert_false(report.eof?)
    assert_equal([["1"], ["2"], ["3"], ["4"]],
                 report.each.map {|row| row.fields})
  end

  def test_each_returns_enumerator_without_block
    report = analyze("1\n2\n")
    assert_kind_of(Enumerator, report.each)
  end

  def test_ragged_rows_extend_columns
    report = analyze("1\n2,extra\n")
    assert_equal(2, report.columns.size)
    assert_true(report.columns[1].nullable?)
    assert_equal("extra",
                 report.columns[1].exclusions[:integer][:examples].first[:value])
  end

  def test_csv_options_are_passed_through
    report = analyze("1;2\n3;4\n", col_sep: ";")
    assert_equal(2, report.columns.size)
    assert_include(report.columns[1].candidates, :integer)
  end

  def test_converter_options_are_forbidden
    error = assert_raise(ArgumentError) do
      CSV::TypeAnalyzer.new(converters: [:integer])
    end
    assert_include(error.message, "converters")
  end

  def test_unknown_option_raises
    assert_raise(ArgumentError) do
      CSV::TypeAnalyzer.new(no_such_option: true)
    end
  end

  def test_invalid_policy_raises
    assert_raise(ArgumentError) do
      CSV::TypeAnalyzer.new(leading_zeros: :bogus)
    end
  end

  def test_to_h
    report = analyze("id,name\n1,x\n", headers: true)
    hash = report.to_h
    assert_equal(1, hash[:sampled_rows])
    assert_true(hash[:eof])
    assert_equal(%i[index header nullable candidates exclusions],
                 hash[:columns][0].keys)
    assert_equal("id", hash[:columns][0][:header])
  end

  def test_does_not_modify_input_values
    data = "007,2024-01-01\n"
    report = analyze(data)
    assert_equal([["007", "2024-01-01"]], report.each.to_a)
  end
end
