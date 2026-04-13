# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/index_planner"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::IndexPlanner) do
  subject(:planner) { described_class.new(client, config, connection) }

  let(:client) { instance_double(MysqlGenius::Core::Ai::Client) }
  let(:config) do
    MysqlGenius::Core::Ai::Config.new(
      client: "openai",
      endpoint: "http://localhost/ai",
      api_key: "k",
      model: "gpt-4",
      auth_style: :bearer,
      system_context: "",
      domain_context: "This is a Rails app.",
    )
  end
  let(:connection) do
    conn = MysqlGenius::Core::Connection::FakeAdapter.new
    conn.stub_tables(["users", "orders", "products"])
    conn.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email", sql_type: "varchar(255)", type: :string, null: false, default: nil, primary_key: false),
    ])
    conn.stub_columns_for("orders", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "user_id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: false),
    ])
    conn.stub_primary_key("users", "id")
    conn.stub_primary_key("orders", "id")
    conn.stub_indexes_for("users", [
      MysqlGenius::Core::IndexDefinition.new(name: "idx_users_email", columns: ["email"], unique: true),
      MysqlGenius::Core::IndexDefinition.new(name: "idx_users_email_name", columns: ["email", "name"], unique: false),
      MysqlGenius::Core::IndexDefinition.new(name: "idx_users_email_dup", columns: ["email"], unique: false),
    ])
    conn.stub_indexes_for("orders", [
      MysqlGenius::Core::IndexDefinition.new(name: "idx_orders_user_id", columns: ["user_id"], unique: false),
    ])
    conn.stub_indexes_for("products", [])
    # UnusedIndexes query
    conn.stub_query(
      /performance_schema\.table_io_waits/i,
      columns: ["table_schema", "table_name", "index_name", "reads", "writes", "table_rows"],
      rows: [["test_db", "users", "idx_users_email_name", "0", "500", "10000"]],
    )
    # DuplicateIndexes uses connection.tables and connection.indexes_for (already stubbed)
    # SchemaContextBuilder: information_schema.tables row count
    conn.stub_query(
      /SELECT TABLE_ROWS FROM information_schema\.tables/i,
      columns: ["TABLE_ROWS"],
      rows: [["10000"]],
    )
    # SchemaContextBuilder: cardinality
    conn.stub_query(
      /information_schema\.STATISTICS/i,
      columns: ["INDEX_NAME", "COLUMN_NAME", "CARDINALITY", "SEQ_IN_INDEX"],
      rows: [
        ["idx_users_email", "email", "10000", "1"],
        ["idx_users_email_name", "email", "10000", "1"],
        ["idx_users_email_name", "name", "9500", "2"],
        ["idx_orders_user_id", "user_id", "5000", "1"],
      ],
    )
    # top_tables_by_size fallback
    conn.stub_query(
      /information_schema\.tables.*ORDER BY.*data_length/i,
      columns: ["table_name"],
      rows: [["users"], ["orders"], ["products"]],
    )
    conn
  end

  it "sends system and user messages to the AI client" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages.length).to(eq(2))
      expect(messages[0][:role]).to(eq("system"))
      expect(messages[1][:role]).to(eq("user"))
    end.and_return({ "plan" => "drop unused indexes" })
    planner.call(["users", "orders"])
  end

  it "includes schema context with cardinality in user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("Schema with cardinality"))
      expect(user_content).to(include("Cardinality:"))
    end.and_return({ "plan" => "all good" })
    planner.call(["users"])
  end

  it "includes unused indexes in user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("Unused indexes"))
      expect(user_content).to(include("idx_users_email_name"))
    end.and_return({ "plan" => "all good" })
    planner.call(["users"])
  end

  it "includes duplicate indexes in user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("Duplicate indexes"))
      expect(user_content).to(include("covered by"))
    end.and_return({ "plan" => "all good" })
    planner.call(["users"])
  end

  it "falls back to top tables by size when no tables given" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("users"))
    end.and_return({ "plan" => "consolidated plan" })
    planner.call
  end

  it "interpolates domain_context into the system prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages[0][:content]).to(include("This is a Rails app"))
    end.and_return({ "plan" => "all good" })
    planner.call(["users"])
  end

  it "returns the parsed AI response" do
    allow(client).to(receive(:chat).and_return({ "plan" => "drop idx_users_email_name" }))
    result = planner.call(["users"])
    expect(result).to(eq({ "plan" => "drop idx_users_email_name" }))
  end
end
