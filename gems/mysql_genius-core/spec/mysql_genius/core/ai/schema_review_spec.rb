# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/schema_review"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::SchemaReview) do
  subject(:builder) { described_class.new(client, config, connection) }

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
    conn.stub_tables(["users", "orders"])
    conn.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
    ])
    conn.stub_columns_for("orders", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
    ])
    conn.stub_indexes_for("users", [])
    conn.stub_indexes_for("orders", [])
    conn.stub_primary_key("users", "id")
    conn.stub_primary_key("orders", "id")
    conn
  end

  it "builds a schema context for a specific table and passes it to the client" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages[0][:role]).to(eq("system"))
      expect(messages[1][:role]).to(eq("user"))
      expect(messages[1][:content]).to(include("Table: users"))
    end.and_return({ "findings" => "none" })
    builder.call("users")
  end

  it "builds a schema context for top queryable tables when table is nil" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages[1][:content]).to(include("Table: users"))
      expect(messages[1][:content]).to(include("Table: orders"))
    end.and_return({ "findings" => "none" })
    builder.call(nil)
  end

  it "interpolates config.domain_context into the system prompt" do
    allow(client).to(receive(:chat)) do |messages:|
      expect(messages[0][:content]).to(include("This is a Rails app"))
    end.and_return({ "findings" => "none" })
    builder.call("users")
  end
end
