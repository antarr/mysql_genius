# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::SlowQueries) do
  subject(:analysis) { described_class.new(connection, threshold_ms: 250, limit: 50) }

  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }

  # The columns performance_schema returns for events_statements_history_long.
  let(:columns) do
    [
      "DIGEST",
      "DIGEST_TEXT",
      "SQL_TEXT",
      "TIMER_WAIT",
      "CURRENT_SCHEMA",
      "ROWS_EXAMINED",
      "ROWS_SENT",
      "NO_INDEX_USED",
      "CREATED_TMP_TABLES",
      "CREATED_TMP_DISK_TABLES",
      "ERRORS",
      "MYSQL_ERRNO",
      "END_EVENT_ID",
    ]
  end

  describe "availability probe" do
    it "reports available when the history_long consumer is enabled" do
      stub_consumer_enabled("YES")

      result = analysis.availability
      expect(result.available?).to(be(true))
      expect(result.reason).to(be_nil)
    end

    it "reports unavailable with an actionable message when the consumer is disabled" do
      stub_consumer_enabled("NO")

      result = analysis.availability
      expect(result.available?).to(be(false))
      expect(result.reason).to(include("disabled"))
      expect(result.reason).to(include("UPDATE performance_schema.setup_consumers"))
    end

    it "reports unavailable when the consumer row is missing (performance_schema off at server level)" do
      connection.stub_query(/FROM performance_schema\.setup_consumers/, columns: ["ENABLED"], rows: [])

      result = analysis.availability
      expect(result.available?).to(be(false))
      expect(result.reason).to(include("not present"))
      expect(result.reason).to(include("performance_schema = OFF"))
    end

    it "reports unavailable when the server refuses the probe query" do
      connection.stub_query(/FROM performance_schema\.setup_consumers/, raises: RuntimeError.new("Access denied"))

      result = analysis.availability
      expect(result.available?).to(be(false))
      expect(result.reason).to(include("performance_schema unreachable"))
      expect(result.reason).to(include("Access denied"))
    end
  end

  describe "#call" do
    it "returns an empty queries array when performance_schema has no slow events" do
      stub_consumer_enabled("YES")
      connection.stub_query(/FROM performance_schema\.events_statements_history_long/, columns: columns, rows: [])

      result = analysis.call
      expect(result.available?).to(be(true))
      expect(result.queries).to(eq([]))
    end

    it "transforms history_long rows into normalized hashes" do
      stub_consumer_enabled("YES")
      connection.stub_query(
        /FROM performance_schema\.events_statements_history_long/,
        columns: columns,
        rows: [
          # 500ms query with full table scan
          [
            "abc123",
            "SELECT * FROM users WHERE email = ?",
            "SELECT * FROM users WHERE email = 'alice@example.com'",
            500_000_000_000, # 500ms in picoseconds
            "app_test",
            10_000, # rows_examined
            1,      # rows_sent
            1,      # no_index_used (MySQL often returns 1/0)
            0, 0, 0, 0, # tmp, tmp_disk, errors, errno
            999, # end_event_id
          ],
        ],
      )

      result = analysis.call
      expect(result.available?).to(be(true))
      expect(result.queries.length).to(eq(1))

      q = result.queries.first
      expect(q).to(include(
        digest: "abc123",
        sql: "SELECT * FROM users WHERE email = 'alice@example.com'",
        digest_text: "SELECT * FROM users WHERE email = ?",
        duration_ms: 500.0,
        rows_examined: 10_000,
        rows_sent: 1,
        rows_ratio: 10_000.0,
        no_index_used: true,
        schema: "app_test",
        source: "performance_schema",
      ))
    end

    it "falls back to DIGEST_TEXT when SQL_TEXT is empty (rare perf_schema edge case)" do
      stub_consumer_enabled("YES")
      connection.stub_query(
        /FROM performance_schema\.events_statements_history_long/,
        columns: columns,
        rows: [
          ["deadbeef", "SELECT 1", "", 300_000_000_000, "test", 1, 1, 0, 0, 0, 0, 0, 1],
        ],
      )

      expect(analysis.call.queries.first[:sql]).to(eq("SELECT 1"))
    end

    it "computes rows_ratio as 0 when rows_sent is 0 (divide-by-zero guard)" do
      stub_consumer_enabled("YES")
      connection.stub_query(
        /FROM performance_schema\.events_statements_history_long/,
        columns: columns,
        rows: [
          ["x", "INSERT INTO logs VALUES (?)", "INSERT INTO logs VALUES (1)", 300_000_000_000, "test", 0, 0, 0, 0, 0, 0, 0, 2],
        ],
      )

      expect(analysis.call.queries.first[:rows_ratio]).to(eq(0))
    end

    it "coerces truthy no_index_used representations to true (1, '1', 'YES', true)" do
      [1, "1", "YES", true].each do |value|
        connection.instance_variable_set(:@stubs, [])
        stub_consumer_enabled("YES")
        connection.stub_query(
          /FROM performance_schema\.events_statements_history_long/,
          columns: columns,
          rows: [["x", "SELECT 1", "SELECT 1", 300_000_000_000, "test", 1, 1, value, 0, 0, 0, 0, 1]],
        )
        expect(analysis.call.queries.first[:no_index_used]).to(eq(true))
      end
    end

    it "coerces falsey no_index_used representations to false (0, '0', 'NO', false, nil)" do
      [0, "0", "NO", false, nil].each do |value|
        connection.instance_variable_set(:@stubs, [])
        stub_consumer_enabled("YES")
        connection.stub_query(
          /FROM performance_schema\.events_statements_history_long/,
          columns: columns,
          rows: [["x", "SELECT 1", "SELECT 1", 300_000_000_000, "test", 1, 1, value, 0, 0, 0, 0, 1]],
        )
        expect(analysis.call.queries.first[:no_index_used]).to(eq(false))
      end
    end

    it "truncates very long SQL_TEXT" do
      stub_consumer_enabled("YES")
      long_sql = "SELECT " + ("a, " * 5000) + "from users"
      connection.stub_query(
        /FROM performance_schema\.events_statements_history_long/,
        columns: columns,
        rows: [["x", "SELECT ?", long_sql, 300_000_000_000, "test", 1, 1, 0, 0, 0, 0, 0, 1]],
      )

      q = analysis.call.queries.first
      expect(q[:sql].length).to(be <= described_class::MAX_SQL_LENGTH)
      expect(q[:sql]).to(end_with("..."))
    end

    it "short-circuits to a not-available Result when consumer is disabled" do
      stub_consumer_enabled("NO")
      # Intentionally do NOT stub the history_long query — it should never be reached.

      result = analysis.call
      expect(result.available?).to(be(false))
      expect(result.queries).to(eq([]))
    end

    it "returns not-available with the exception message when history_long query raises" do
      stub_consumer_enabled("YES")
      connection.stub_query(/FROM performance_schema\.events_statements_history_long/, raises: RuntimeError.new("Table 'performance_schema.events_statements_history_long' doesn't exist"))

      result = analysis.call
      expect(result.available?).to(be(false))
      expect(result.reason).to(include("performance_schema query failed"))
      expect(result.queries).to(eq([]))
    end
  end

  describe "SQL construction" do
    it "embeds the threshold in picoseconds in the WHERE clause" do
      stub_consumer_enabled("YES")
      captured_sql = nil
      connection.stub_query(/FROM performance_schema\.events_statements_history_long/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql if sql.include?("events_statements_history_long")
        original.call(sql, **kwargs)
      end)

      described_class.new(connection, threshold_ms: 1000).call
      # 1000ms = 1,000,000,000,000 picoseconds
      expect(captured_sql).to(include("TIMER_WAIT > 1000000000000"))
    end

    it "clamps the limit to the hard cap of 1000" do
      stub_consumer_enabled("YES")
      captured_sql = nil
      connection.stub_query(/FROM performance_schema\.events_statements_history_long/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql if sql.include?("events_statements_history_long")
        original.call(sql, **kwargs)
      end)

      described_class.new(connection, limit: 99_999).call
      expect(captured_sql).to(include("LIMIT 1000"))
    end

    it "filters out information_schema, performance_schema, and noise statements" do
      stub_consumer_enabled("YES")
      captured_sql = nil
      connection.stub_query(/FROM performance_schema\.events_statements_history_long/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql if sql.include?("events_statements_history_long")
        original.call(sql, **kwargs)
      end)

      analysis.call
      expect(captured_sql).to(include("NOT LIKE '%information_schema.%'"))
      expect(captured_sql).to(include("NOT LIKE '%performance_schema.%'"))
      expect(captured_sql).to(include("NOT LIKE 'EXPLAIN%'"))
      expect(captured_sql).to(include("NOT LIKE 'SHOW %'"))
      expect(captured_sql).to(include("NOT LIKE 'COMMIT%'"))
    end
  end

  def stub_consumer_enabled(value)
    connection.stub_query(
      /FROM performance_schema\.setup_consumers/,
      columns: ["ENABLED"],
      rows: [[value]],
    )
  end
end
