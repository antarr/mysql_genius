# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"

RSpec.describe("GET /columns", type: :request) do
  before do
    users_columns = [
      MysqlGenius::Core::ColumnDefinition.new(name: "id",       sql_type: "bigint",       type: :integer, null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email",    sql_type: "varchar(255)", type: :string,  null: false, default: nil, primary_key: false),
      MysqlGenius::Core::ColumnDefinition.new(name: "password", sql_type: "varchar(255)", type: :string,  null: false, default: nil, primary_key: false),
    ]
    @fake_adapter.stub_tables(["users"])
    @fake_adapter.stub_columns_for("users", users_columns)
  end

  it "returns :ok with visible columns for an allowed table" do
    @test_config.instance_variable_set(:@security, MysqlGenius::Desktop::Config::SecurityConfig.from_hash({ "masked_column_patterns" => ["password"] }))
    get "/columns?table=users"
    expect(last_response.status).to(eq(200))
    body = JSON.parse(last_response.body)
    names = body.map { |c| c["name"] }
    expect(names).to(eq(["id", "email"]))
  end

  it "returns 403 for a blocked table" do
    @test_config.instance_variable_set(:@security, MysqlGenius::Desktop::Config::SecurityConfig.from_hash({ "blocked_tables" => ["users"] }))
    get "/columns?table=users"
    expect(last_response.status).to(eq(403))
    body = JSON.parse(last_response.body)
    expect(body["error"]).to(include("not available for querying"))
  end

  it "returns 404 for a missing table" do
    get "/columns?table=nonexistent"
    expect(last_response.status).to(eq(404))
    body = JSON.parse(last_response.body)
    expect(body["error"]).to(include("does not exist"))
  end
end
# rubocop:enable RSpec/InstanceVariable
