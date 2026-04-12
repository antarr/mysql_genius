# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"

RSpec.describe("POST /execute", type: :request) do
  before do
    @fake_adapter.stub_tables(["users"])
    @fake_adapter.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id",    sql_type: "bigint",       type: :integer, null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email", sql_type: "varchar(255)", type: :string,  null: false, default: nil, primary_key: false),
    ])
  end

  it "returns 200 with columns, rows, and execution metrics on success" do
    @fake_adapter.stub_query(/SELECT.*FROM users/, columns: ["id", "email"], rows: [[1, "alice@example.com"]])
    post "/execute", sql: "SELECT id, email FROM users LIMIT 10"
    expect(last_response.status).to(eq(200))
    body = JSON.parse(last_response.body)
    expect(body["columns"]).to(eq(["id", "email"]))
    expect(body["rows"]).to(eq([[1, "alice@example.com"]]))
    expect(body["row_count"]).to(eq(1))
    expect(body["truncated"]).to(be(false))
    expect(body["execution_time_ms"]).to(be_a(Numeric))
  end

  it "masks columns matching masked_column_patterns" do
    @test_config.instance_variable_set(:@security, MysqlGenius::Desktop::Config::SecurityConfig.from_hash({ "masked_column_patterns" => ["email"] }))
    @fake_adapter.stub_query(/SELECT.*FROM users/, columns: ["id", "email"], rows: [[1, "alice@example.com"]])
    post "/execute", sql: "SELECT id, email FROM users LIMIT 10"
    body = JSON.parse(last_response.body)
    expect(body["rows"]).to(eq([[1, "[REDACTED]"]]))
  end

  it "returns 422 with the rejection reason when SQL is not SELECT" do
    post "/execute", sql: "DELETE FROM users"
    expect(last_response.status).to(eq(422))
    body = JSON.parse(last_response.body)
    expect(body["error"]).to(match(/SELECT|not allowed/i))
  end

  it "returns 422 when a timeout error is raised" do
    @fake_adapter.stub_query(/SELECT.*FROM users/, raises: StandardError.new("max_execution_time exceeded"))
    post "/execute", sql: "SELECT id FROM users"
    expect(last_response.status).to(eq(422))
    body = JSON.parse(last_response.body)
    expect(body["timeout"]).to(be(true))
    expect(body["error"]).to(include("timeout"))
  end

  it "clamps row_limit to the configured maximum" do
    @test_config.instance_variable_set(:@query, MysqlGenius::Desktop::Config::QueryConfig.from_hash({ "max_row_limit" => 50 }))
    @fake_adapter.stub_query(/SELECT.*FROM users/, columns: ["id"], rows: [])
    post "/execute", sql: "SELECT id FROM users", row_limit: "999999"
    expect(last_response.status).to(eq(200))
  end
end
# rubocop:enable RSpec/InstanceVariable
