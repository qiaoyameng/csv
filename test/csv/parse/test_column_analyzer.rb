# -*- coding: utf-8 -*-
# frozen_string_literal: true

require_relative "../helper"

class TestCSVColumnAnalyzer < Test::Unit::TestCase
  extend DifferentOFS

  def analyze(data, **options)
    CSV.analyze_columns(data, **options)
  end

  def test_candidate_types_and_later_rejection
    report = analyze("1,12.30,2024-01-02,2024-01-02T03:04:05Z,abc\n")

    assert_equal([:integer, :bigdecimal, :string],
                 report.columns[0].possible_converters)
    assert_equal([:bigdecimal, :string],
                 report.columns[1].possible_converters)
    assert_equal([:date, :string],
                 report.columns[2].possible_converters)
    assert_equal([:time_with_zone, :string],
                 report.columns[3].possible_converters)
    assert_equal([:string],
                 report.columns[4].possible_converters)

    report = analyze("1\nx\n")
    integer = report.columns[0].rejected_converters[:integer]
    assert_equal("not an integer", integer[:reason])
    assert_equal(2, integer[:examples].first.line)
    assert_equal(1, integer[:examples].first.column)
  end

  def test_leading_zero_and_oversized_integer_policies
    report = analyze("01\n")
    assert_equal([:string], report.columns[0].possible_converters)

    report = analyze("01\n", leading_zeros: :allow)
    assert_equal([:integer, :bigdecimal, :string],
                 report.columns[0].possible_converters)

    report = analyze("01\n", leading_zeros: :allow_decimal)
    assert_equal([:bigdecimal, :string],
                 report.columns[0].possible_converters)

    huge = (2 ** 63).to_s
    report = analyze("#{huge}\n")
    assert_equal([:bigdecimal, :string],
                 report.columns[0].possible_converters)
    report = analyze("#{huge}\n", oversized_integer: :integer)
    assert_include(report.columns[0].possible_converters, :integer)
    report = analyze("#{huge}\n", oversized_integer: :string)
    assert_equal([:string], report.columns[0].possible_converters)
  end

  def test_empty_and_quoted_empty_policies
    report = analyze(",\"\"\n")

    assert_equal(true, report.columns[0].nullable)
    assert_equal(1, report.columns[0].unquoted_empty_count)
    assert_equal(false, report.columns[1].nullable)
    assert_equal(1, report.columns[1].quoted_empty_count)

    report = analyze(",\"\"\n",
                     unquoted_empty: :empty_string,
                     quoted_empty: :null)
    assert_equal(false, report.columns[0].nullable)
    assert_equal(true, report.columns[1].nullable)
    assert_equal([:string], report.columns[0].possible_converters)
  end

  def test_examples_are_limited_and_redacted
    data = 6.times.map {|i| "value#{i}" }.join("\n") + "\n"
    report = analyze(data, max_examples: 2)
    examples = report.columns[0].rejected_converters[:integer][:examples]

    assert_equal(2, examples.size)
    assert_equal("••••••", examples.first.value)

    report = analyze(data, max_examples: 2, redact_values: false)
    examples = report.columns[0].rejected_converters[:integer][:examples]
    assert_equal("value0", examples.first.value)
  end

  def test_duplicate_headers_are_separate_by_position
    report = analyze("name,name\n1,abc\n", headers: true)

    assert_equal(["name", "name"], report.headers)
    assert_include(report.columns[0].possible_converters, :integer)
    assert_not_include(report.columns[1].possible_converters, :integer)
  end

  def test_ragged_rows_count_missing_cells_by_position
    report = analyze("a,b\nx\n", headers: true)

    assert_equal(1, report.columns[1].missing_count)
    assert_equal(true, report.columns[1].nullable)
  end

  def test_one_pass_io_can_replay_and_then_continue
    io = StringIO.new("1\nx\ny\n")

    analyzer = CSV::ColumnAnalyzer.new(io)
    analyzer.sample(1)

    assert_equal([["1"], ["x"]], analyzer.replay.to_a)
    assert_equal([["y"]], analyzer.continue.to_a)
    assert_equal(true, analyzer.eof?)

    io = StringIO.new("1\nx\ny\n")
    analyzer = CSV::ColumnAnalyzer.new(io)
    analyzer.sample(1)

    assert_equal([["x"], ["y"]], analyzer.continue.to_a)
  end

  def test_lookahead_rejection_replay_and_continue
    analyzer = CSV::ColumnAnalyzer.new("1\nx\n")
    analyzer.sample(1)
    report = analyzer.report

    assert_equal(1, report.sample_records)
    assert_equal(2, report.analyzed_records)
    assert_equal(true, report.eof?)
    assert_equal([:string], report.columns[0].possible_converters)

    assert_equal([["1"], ["x"]], analyzer.replay.to_a)
    assert_equal([["1"], ["x"]], analyzer.replay.to_a)
    assert_equal([], analyzer.continue.to_a)

    analyzer = CSV::ColumnAnalyzer.new("1\nx\ny\n")
    analyzer.sample(1)
    assert_equal([["x"], ["y"]], analyzer.continue.to_a)

    report = analyze("1\nx\n", sample_records: 10)
    assert_equal(true, report.eof?)
  end

  def test_input_is_not_modified
    data = +"1\n"
    analyze(data.freeze)

    assert_equal("1\n", data)
  end

  def test_managed_csv_options_cannot_rewrite_analyzed_values
    assert_raise(ArgumentError) do
      CSV::ColumnAnalyzer.new("1\n", converters: :integer)
    end
  end
end
