# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::QueryStats) do
  subject(:analysis) { described_class.new(connection) }

  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }

  before do
    connection.stub_current_database("app_test")
  end

  describe "#call" do
    let(:columns) do
      [
        "DIGEST",
        "DIGEST_TEXT",
        "calls",
        "total_time_ms",
        "avg_time_ms",
        "max_time_ms",
        "rows_examined",
        "rows_sent",
        "tmp_disk_tables",
        "sort_rows",
        "FIRST_SEEN",
        "LAST_SEEN",
      ]
    end

    it "returns an empty array when performance_schema has no digest rows" do
      connection.stub_query(/performance_schema\.events_statements_summary_by_digest/, columns: columns, rows: [])

      expect(analysis.call).to(eq([]))
    end

    it "transforms digest rows into hashes keyed by symbol" do
      connection.stub_query(
        /performance_schema\.events_statements_summary_by_digest/,
        columns: columns,
        rows: [
          ["abc123def456", "SELECT * FROM users WHERE id = ?", 100, 500.5, 5.005, 42.1, 1000, 100, 0, 0, "2026-04-01T00:00:00Z", "2026-04-10T00:00:00Z"],
        ],
      )

      result = analysis.call

      expect(result.length).to(eq(1))
      expect(result.first).to(include(
        digest: "abc123def456",
        sql: "SELECT * FROM users WHERE id = ?",
        calls: 100,
        total_time_ms: 500.5,
        avg_time_ms: 5.005,
        max_time_ms: 42.1,
        rows_examined: 1000,
        rows_sent: 100,
        rows_ratio: 10.0,
      ))
    end

    it "computes rows_ratio as 0 when rows_sent is 0" do
      connection.stub_query(
        /performance_schema\.events_statements_summary_by_digest/,
        columns: columns,
        rows: [["deadbeef", "SET NAMES ?", 50, 10.0, 0.2, 1.0, 0, 0, 0, 0, nil, nil]],
      )

      expect(analysis.call.first[:rows_ratio]).to(eq(0))
    end

    it "defaults to sorting by SUM_TIMER_WAIT DESC (sort=total_time)" do
      captured_sql = nil
      connection.stub_query(/performance_schema\.events_statements_summary_by_digest/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      analysis.call(sort: "total_time")
      expect(captured_sql).to(match(/ORDER BY SUM_TIMER_WAIT DESC/))
    end

    it "supports sort=avg_time" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      analysis.call(sort: "avg_time")
      expect(captured_sql).to(match(/ORDER BY AVG_TIMER_WAIT DESC/))
    end

    it "supports sort=calls" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      analysis.call(sort: "calls")
      expect(captured_sql).to(match(/ORDER BY COUNT_STAR DESC/))
    end

    it "supports sort=rows_examined" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      analysis.call(sort: "rows_examined")
      expect(captured_sql).to(match(/ORDER BY SUM_ROWS_EXAMINED DESC/))
    end

    it "rejects invalid sort values and falls back to total_time" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      analysis.call(sort: "' OR 1=1 --")
      expect(captured_sql).to(match(/ORDER BY SUM_TIMER_WAIT DESC/))
    end

    it "clamps limit to a max of 50" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      analysis.call(limit: 99)
      expect(captured_sql).to(match(/LIMIT 50/))
    end

    it "accepts a limit smaller than the max" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      analysis.call(limit: 5)
      expect(captured_sql).to(match(/LIMIT 5/))
    end

    it "truncates long digest text to 500 characters" do
      long_digest = "SELECT * FROM users WHERE " + ("foo = 1 AND " * 100)
      connection.stub_query(
        /performance_schema/,
        columns: columns,
        rows: [["abc999", long_digest, 1, 1.0, 1.0, 1.0, 1, 1, 0, 0, nil, nil]],
      )

      result = analysis.call
      expect(result.first[:sql].length).to(be <= 500)
    end
  end
end
