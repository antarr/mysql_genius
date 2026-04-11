# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/rewrite_query"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::RewriteQuery) do
  subject(:builder) { described_class.new(client, config, connection) }

  let(:client) { instance_double(MysqlGenius::Core::Ai::Client) }
  let(:config) do
    MysqlGenius::Core::Ai::Config.new(
      client: "openai",
      endpoint: "x",
      api_key: "k",
      model: "m",
      auth_style: :bearer,
      system_context: "",
    )
  end
  let(:connection) do
    conn = MysqlGenius::Core::Connection::FakeAdapter.new
    conn.stub_tables(["users"])
    conn.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
    ])
    conn.stub_indexes_for("users", [])
    conn.stub_primary_key("users", "id")
    conn
  end

  it "extracts tables from the SQL and includes their schema in the user message" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages[1][:content]).to(eq("SELECT id FROM users"))
      expect(messages[0][:content]).to(include("Available schema:"))
      expect(messages[0][:content]).to(include("Table: users"))
    end.and_return({ "original" => "SELECT id FROM users", "rewritten" => "SELECT id FROM users", "changes" => "none" })
    builder.call("SELECT id FROM users")
  end
end
