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
end
# rubocop:enable RSpec/InstanceVariable
