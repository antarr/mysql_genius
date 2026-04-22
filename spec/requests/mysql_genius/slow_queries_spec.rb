# frozen_string_literal: true

require "rails_helper"

RSpec.describe("GET /mysql_genius/primary/slow_queries", type: :request) do
  let(:history_long_columns) do
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

  let(:consumer_result) { fake_result(columns: ["ENABLED"], rows: [["YES"]]) }
  let(:consumer_off_result) { fake_result(columns: ["ENABLED"], rows: [["NO"]]) }

  def slow_rows(rows)
    fake_result(columns: history_long_columns, rows: rows)
  end

  describe "perf_schema as the default source (no Redis configured)" do
    it "returns perf_schema slow queries tagged with source=performance_schema" do
      stub_connection(
        tables: [],
        exec_query: {
          /FROM performance_schema\.setup_consumers/ => consumer_result,
          /FROM performance_schema\.events_statements_history_long/ => slow_rows([
            ["abc", "SELECT * FROM orders WHERE id = ?", "SELECT * FROM orders WHERE id = 5",
             500_000_000_000, "app_test", 10_000, 1, 1, 0, 0, 0, 0, 1],
          ]),
        },
      )

      get "/mysql_genius/primary/slow_queries"
      expect(last_response).to(be_ok)
      body = JSON.parse(last_response.body)
      expect(body.length).to(eq(1))
      expect(body.first).to(include(
        "sql" => "SELECT * FROM orders WHERE id = 5",
        "digest" => "abc",
        "duration_ms" => 500.0,
        "source" => "performance_schema",
      ))
    end

    it "returns an empty array when perf_schema has no slow events" do
      stub_connection(
        tables: [],
        exec_query: {
          /FROM performance_schema\.setup_consumers/ => consumer_result,
          /FROM performance_schema\.events_statements_history_long/ => slow_rows([]),
        },
      )

      get "/mysql_genius/primary/slow_queries"
      expect(last_response).to(be_ok)
      expect(JSON.parse(last_response.body)).to(eq([]))
    end

    it "degrades to an empty array when the history_long consumer is disabled (not a 500)" do
      stub_connection(
        tables: [],
        exec_query: {
          /FROM performance_schema\.setup_consumers/ => consumer_off_result,
        },
        allow_unmatched_exec_query: true,
      )

      get "/mysql_genius/primary/slow_queries"
      expect(last_response).to(be_ok)
      expect(JSON.parse(last_response.body)).to(eq([]))
    end

    it "degrades to an empty array when performance_schema is unreachable" do
      stub_connection(tables: [], allow_unmatched_exec_query: true)
      allow(ActiveRecord::Base.connection).to(receive(:exec_query))
        .with(/FROM performance_schema\.setup_consumers/)
        .and_raise(StandardError, "Access denied")

      get "/mysql_genius/primary/slow_queries"
      expect(last_response).to(be_ok)
      expect(JSON.parse(last_response.body)).to(eq([]))
    end
  end

  describe "sorting and capping" do
    it "sorts results by duration_ms desc" do
      stub_connection(
        tables: [],
        exec_query: {
          /FROM performance_schema\.setup_consumers/ => consumer_result,
          /FROM performance_schema\.events_statements_history_long/ => slow_rows([
            ["a", "SELECT 1", "SELECT 1", 300_000_000_000, "t", 1, 1, 0, 0, 0, 0, 0, 1],   # 300ms
            ["b", "SELECT 2", "SELECT 2", 1_200_000_000_000, "t", 1, 1, 0, 0, 0, 0, 0, 2], # 1200ms
            ["c", "SELECT 3", "SELECT 3", 800_000_000_000, "t", 1, 1, 0, 0, 0, 0, 0, 3],   # 800ms
          ]),
        },
      )

      get "/mysql_genius/primary/slow_queries"
      durations = JSON.parse(last_response.body).map { |q| q["duration_ms"] }
      expect(durations).to(eq([1200.0, 800.0, 300.0]))
    end
  end

  describe "Redis augmentation (when c.redis_url is set)" do
    before do
      # The redis gem isn't a runtime dep; controller does `require "redis"`
      # on demand. Define a minimal top-level stub (the require becomes a
      # no-op because the constant already exists) and bypass the gem load.
      stub_const("Redis", Class.new) unless defined?(Redis)
      allow_any_instance_of(MysqlGenius::QueriesController).to(receive(:require).and_call_original)
      allow_any_instance_of(MysqlGenius::QueriesController).to(receive(:require).with("redis").and_return(true))
      MysqlGenius.configure { |c| c.redis_url = "redis://localhost:6379/0" }
    end
    after  { MysqlGenius.configure { |c| c.redis_url = nil } }

    it "merges perf_schema and Rails-side queries, sorted by duration desc" do
      stub_connection(
        tables: [],
        exec_query: {
          /FROM performance_schema\.setup_consumers/ => consumer_result,
          /FROM performance_schema\.events_statements_history_long/ => slow_rows([
            ["mysql_side_digest", "SELECT 1", "SELECT 1", 300_000_000_000, "t", 1, 1, 0, 0, 0, 0, 0, 1], # 300ms
          ]),
        },
      )

      fake_redis = double("Redis")
      allow(fake_redis).to(receive(:lrange).and_return([
        { sql: "SELECT 2", duration_ms: 1500.0, timestamp: "2026-04-22T15:30:00Z", name: "User Load" }.to_json,
      ]))
      allow(Redis).to(receive(:new).and_return(fake_redis))

      get "/mysql_genius/primary/slow_queries"
      body = JSON.parse(last_response.body)
      expect(body.length).to(eq(2))
      expect(body.map { |q| q["source"] }).to(eq(["rails", "performance_schema"]))
      expect(body.map { |q| q["duration_ms"] }).to(eq([1500.0, 300.0]))
    end

    it "does not fail the endpoint when Redis is unreachable — still returns perf_schema results" do
      stub_connection(
        tables: [],
        exec_query: {
          /FROM performance_schema\.setup_consumers/ => consumer_result,
          /FROM performance_schema\.events_statements_history_long/ => slow_rows([
            ["x", "SELECT 1", "SELECT 1", 500_000_000_000, "t", 1, 1, 0, 0, 0, 0, 0, 1],
          ]),
        },
      )

      fake_redis = double("Redis")
      allow(fake_redis).to(receive(:lrange).and_raise(StandardError, "Connection refused"))
      allow(Redis).to(receive(:new).and_return(fake_redis))

      get "/mysql_genius/primary/slow_queries"
      body = JSON.parse(last_response.body)
      expect(body.length).to(eq(1))
      expect(body.first["source"]).to(eq("performance_schema"))
    end
  end

  describe "response shape backward-compat" do
    it "returns a bare JSON array (not wrapped in an object) for existing frontend compatibility" do
      stub_connection(
        tables: [],
        exec_query: {
          /FROM performance_schema\.setup_consumers/ => consumer_off_result,
        },
        allow_unmatched_exec_query: true,
      )

      get "/mysql_genius/primary/slow_queries"
      body = JSON.parse(last_response.body)
      expect(body).to(be_an(Array))
    end
  end
end
