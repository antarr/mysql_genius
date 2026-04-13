# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/pattern_grouper"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::PatternGrouper) do
  subject(:grouper) { described_class.new(connection, client, config) }

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
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:high_cost_stats) do
    [
      {
        digest: "abc123",
        sql: "SELECT `users` . * FROM `users` WHERE `email` = ?",
        calls: 5000,
        total_time_ms: 12000.0,
        avg_time_ms: 2.4,
        max_time_ms: 50.0,
        rows_examined: 500_000,
        rows_sent: 5000,
        rows_ratio: 100.0,
        tmp_disk_tables: 0,
        sort_rows: 0,
        first_seen: "2026-04-01",
        last_seen: "2026-04-13",
      },
      {
        digest: "def456",
        sql: "SELECT COUNT ( * ) FROM `orders` WHERE `status` = ?",
        calls: 200,
        total_time_ms: 8000.0,
        avg_time_ms: 40.0,
        max_time_ms: 120.0,
        rows_examined: 1_000_000,
        rows_sent: 200,
        rows_ratio: 5000.0,
        tmp_disk_tables: 10,
        sort_rows: 0,
        first_seen: "2026-04-05",
        last_seen: "2026-04-13",
      },
    ]
  end
  let(:low_cost_stats) do
    [
      {
        digest: "ghi789",
        sql: "SELECT 1",
        calls: 100,
        total_time_ms: 10.0,
        avg_time_ms: 0.1,
        max_time_ms: 1.0,
        rows_examined: 100,
        rows_sent: 100,
        rows_ratio: 1.0,
        tmp_disk_tables: 0,
        sort_rows: 0,
        first_seen: "2026-04-01",
        last_seen: "2026-04-13",
      },
    ]
  end

  before do
    connection.stub_tables(["users", "orders"])
    connection.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email", sql_type: "varchar(255)", type: :string, null: false, default: nil, primary_key: false),
    ])
    connection.stub_columns_for("orders", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "status", sql_type: "varchar(50)", type: :string, null: false, default: nil, primary_key: false),
    ])
    connection.stub_primary_key("users", "id")
    connection.stub_primary_key("orders", "id")
    connection.stub_indexes_for("users", [])
    connection.stub_indexes_for("orders", [])
    connection.stub_query(/TABLE_ROWS/i, columns: ["TABLE_ROWS"], rows: [["50000"]])
  end

  context "when high-cost queries exist" do
    before do
      query_stats_instance = instance_double(MysqlGenius::Core::Analysis::QueryStats)
      allow(MysqlGenius::Core::Analysis::QueryStats).to(receive(:new).with(connection).and_return(query_stats_instance))
      allow(query_stats_instance).to(receive(:call).with(sort: "total_time", limit: 30).and_return(high_cost_stats))
    end

    it "sends system and user messages to the AI client" do
      expect(client).to(receive(:chat)) do |messages:|
        expect(messages.length).to(eq(2))
        expect(messages[0][:role]).to(eq("system"))
        expect(messages[1][:role]).to(eq("user"))
      end.and_return({ "groups" => "grouped analysis" })
      grouper.call
    end

    it "includes high-cost query SQL in the user prompt" do
      expect(client).to(receive(:chat)) do |messages:|
        user_content = messages[1][:content]
        expect(user_content).to(include("SELECT `users`"))
        expect(user_content).to(include("SELECT COUNT"))
        expect(user_content).to(include("rows_ratio=100.0"))
        expect(user_content).to(include("rows_ratio=5000.0"))
      end.and_return({ "groups" => "grouped analysis" })
      grouper.call
    end

    it "includes schema context for referenced tables" do
      expect(client).to(receive(:chat)) do |messages:|
        user_content = messages[1][:content]
        expect(user_content).to(include("Schema context"))
        expect(user_content).to(include("Table: users"))
        expect(user_content).to(include("Table: orders"))
      end.and_return({ "groups" => "grouped analysis" })
      grouper.call
    end

    it "interpolates domain_context into the system prompt" do
      expect(client).to(receive(:chat)) do |messages:|
        expect(messages[0][:content]).to(include("This is a Rails app"))
      end.and_return({ "groups" => "grouped analysis" })
      grouper.call
    end

    it "returns the parsed AI response" do
      allow(client).to(receive(:chat).and_return({ "groups" => "missing index on users.email" }))
      result = grouper.call
      expect(result).to(eq({ "groups" => "missing index on users.email" }))
    end
  end

  context "when no high-cost queries exist" do
    before do
      query_stats_instance = instance_double(MysqlGenius::Core::Analysis::QueryStats)
      allow(MysqlGenius::Core::Analysis::QueryStats).to(receive(:new).with(connection).and_return(query_stats_instance))
      allow(query_stats_instance).to(receive(:call).with(sort: "total_time", limit: 30).and_return(low_cost_stats))
    end

    it "returns early with a message" do
      result = grouper.call
      expect(result).to(eq({ "groups" => "No high-cost queries found to analyze." }))
    end
  end
end
