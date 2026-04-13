# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"

RSpec.describe("AI feature routes", type: :request) do
  # Canned response hash deliberately contains every key any of the 7 AI services might look up.
  let(:canned_ai_response) do
    {
      "sql" => "SELECT * FROM users LIMIT 10",
      "explanation" => "fetches users",
      "findings" => "schema looks fine",
      "indexes" => "none recommended",
      "suggestions" => "none",
      "original" => "SELECT * FROM users",
      "rewritten" => "SELECT id, email FROM users",
      "changes" => "narrowed column list",
      "risk_level" => "low",
      "assessment" => "safe to run",
    }
  end

  let(:fake_ai_client) { instance_double(MysqlGenius::Core::Ai::Client, chat: canned_ai_response) }

  before do
    @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.new(
      enabled: true,
      endpoint: "https://api.example.com/v1/chat/completions",
      api_key: "test-key",
      model: "gpt-4o-mini",
      auth_style: :bearer,
      system_context: "",
      domain_context: "",
    ))
    # Every route handler builds a Core::Ai::Client via .new; intercept that
    # single construction site and return the fake for every downstream call.
    allow(MysqlGenius::Core::Ai::Client).to(receive(:new).and_return(fake_ai_client))

    @fake_adapter.stub_tables(["users"])
    @fake_adapter.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
    ])

    # Stubs for new AI service classes that query SHOW / performance_schema
    @fake_adapter.stub_query(/SHOW GLOBAL VARIABLES/i, columns: ["Variable_name", "Value"], rows: [
      ["innodb_buffer_pool_size", "134217728"],
      ["max_connections", "151"],
      ["wait_timeout", "28800"],
      ["interactive_timeout", "28800"],
      ["thread_cache_size", "8"],
    ])
    @fake_adapter.stub_query(/SHOW GLOBAL STATUS/i, columns: ["Variable_name", "Value"], rows: [
      ["Threads_connected", "5"],
      ["Threads_running", "1"],
      ["Max_used_connections", "10"],
      ["Aborted_connects", "0"],
      ["Aborted_clients", "0"],
      ["Connections", "100"],
      ["Threads_created", "15"],
      ["Innodb_buffer_pool_reads", "100"],
      ["Innodb_buffer_pool_read_requests", "10000"],
      ["Innodb_buffer_pool_pages_total", "8192"],
      ["Innodb_buffer_pool_pages_free", "4096"],
      ["Innodb_buffer_pool_pages_dirty", "10"],
      ["Innodb_row_lock_waits", "0"],
      ["Innodb_row_lock_time", "0"],
      ["Slow_queries", "0"],
      ["Questions", "5000"],
      ["Com_select", "3000"],
      ["Com_insert", "500"],
      ["Com_update", "300"],
      ["Com_delete", "100"],
      ["Created_tmp_disk_tables", "5"],
      ["Uptime", "86400"],
    ])
    @fake_adapter.stub_query(/SHOW ENGINE INNODB STATUS/i, columns: ["Type", "Name", "Status"], rows: [
      ["InnoDB", "", "=====================================\nINNODB MONITOR OUTPUT\n====================================="],
    ])
    @fake_adapter.stub_query(
      /performance_schema\.events_statements_summary_by_digest/i,
      columns: [
        "DIGEST_TEXT",
        "COUNT_STAR",
        "SUM_TIMER_WAIT",
        "AVG_TIMER_WAIT",
        "MAX_TIMER_WAIT",
        "SUM_ROWS_EXAMINED",
        "SUM_ROWS_SENT",
        "SUM_CREATED_TMP_DISK_TABLES",
        "SUM_CREATED_TMP_TABLES",
        "FIRST_SEEN",
        "LAST_SEEN",
      ],
      rows: [],
    )
    @fake_adapter.stub_query(
      /performance_schema\.table_io_waits/i,
      columns: [
        "OBJECT_SCHEMA", "OBJECT_NAME", "INDEX_NAME", "COUNT_READ", "COUNT_WRITE",
      ],
      rows: [],
    )
    @fake_adapter.stub_query(
      /information_schema\.STATISTICS/i,
      columns: [
        "TABLE_NAME",
        "INDEX_NAME",
        "COLUMN_NAME",
        "SEQ_IN_INDEX",
        "NON_UNIQUE",
        "CARDINALITY",
      ],
      rows: [],
    )
    @fake_adapter.stub_query(
      /information_schema\.TABLES/i,
      columns: [
        "TABLE_NAME", "TABLE_ROWS", "DATA_LENGTH", "INDEX_LENGTH",
      ],
      rows: [["users", "100", "16384", "8192"]],
    )
    @fake_adapter.stub_query(/SELECT VERSION/i, columns: ["VERSION()"], rows: [["8.0.35"]])
  end

  describe "POST /suggest" do
    it "returns JSON with sql and explanation" do
      post "/suggest", prompt: "show me users"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["sql"]).to(include("SELECT"))
      expect(body["explanation"]).to(include("users"))
    end

    it "returns 422 when the prompt is blank" do
      post "/suggest", prompt: "   "
      expect(last_response.status).to(eq(422))
    end

    it "returns 404 when AI is not configured" do
      @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.from_hash({}))
      post "/suggest", prompt: "anything"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /optimize" do
    it "returns JSON when given sql and explain_rows" do
      post "/optimize", sql: "SELECT * FROM users", explain_rows: [["1", "SIMPLE", "users"]]
      expect(last_response.status).to(eq(200))
    end

    it "returns 422 when sql or explain_rows is blank" do
      post "/optimize", sql: "", explain_rows: []
      expect(last_response.status).to(eq(422))
    end
  end

  describe "POST /describe_query" do
    it "delegates to Core::Ai::DescribeQuery" do
      post "/describe_query", sql: "SELECT 1"
      expect(last_response.status).to(eq(200))
    end

    it "returns 422 when sql is blank" do
      post "/describe_query", sql: ""
      expect(last_response.status).to(eq(422))
    end
  end

  describe "POST /schema_review" do
    it "delegates to Core::Ai::SchemaReview" do
      post "/schema_review", table: "users"
      expect(last_response.status).to(eq(200))
    end
  end

  describe "POST /rewrite_query" do
    it "delegates to Core::Ai::RewriteQuery" do
      post "/rewrite_query", sql: "SELECT * FROM users"
      expect(last_response.status).to(eq(200))
    end
  end

  describe "POST /index_advisor" do
    it "delegates to Core::Ai::IndexAdvisor" do
      post "/index_advisor", sql: "SELECT * FROM users", explain_rows: [["1", "SIMPLE", "users"]]
      expect(last_response.status).to(eq(200))
    end
  end

  describe "POST /migration_risk" do
    it "delegates to Core::Ai::MigrationRisk" do
      post "/migration_risk", migration: "ALTER TABLE users ADD INDEX idx_email (email)"
      expect(last_response.status).to(eq(200))
    end

    it "returns 422 when migration is blank" do
      post "/migration_risk", migration: ""
      expect(last_response.status).to(eq(422))
    end
  end

  describe "POST /variable_review" do
    it "delegates to Core::Ai::VariableReviewer" do
      post "/variable_review"
      expect(last_response.status).to(eq(200))
    end

    it "returns 404 when AI is not configured" do
      @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.from_hash({}))
      post "/variable_review"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /connection_advisor" do
    it "delegates to Core::Ai::ConnectionAdvisor" do
      post "/connection_advisor"
      expect(last_response.status).to(eq(200))
    end

    it "returns 404 when AI is not configured" do
      @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.from_hash({}))
      post "/connection_advisor"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /workload_digest" do
    it "delegates to Core::Ai::WorkloadDigest" do
      post "/workload_digest"
      expect(last_response.status).to(eq(200))
    end

    it "returns 404 when AI is not configured" do
      @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.from_hash({}))
      post "/workload_digest"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /innodb_health" do
    it "delegates to Core::Ai::InnodbInterpreter" do
      post "/innodb_health"
      expect(last_response.status).to(eq(200))
    end

    it "returns 404 when AI is not configured" do
      @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.from_hash({}))
      post "/innodb_health"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /index_planner" do
    it "delegates to Core::Ai::IndexPlanner" do
      post "/index_planner"
      expect(last_response.status).to(eq(200))
    end

    it "returns 404 when AI is not configured" do
      @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.from_hash({}))
      post "/index_planner"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /pattern_grouper" do
    it "delegates to Core::Ai::PatternGrouper" do
      post "/pattern_grouper"
      expect(last_response.status).to(eq(200))
    end

    it "returns 404 when AI is not configured" do
      @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.from_hash({}))
      post "/pattern_grouper"
      expect(last_response.status).to(eq(404))
    end
  end
end
# rubocop:enable RSpec/InstanceVariable
