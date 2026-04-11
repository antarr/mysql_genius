# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/migration_risk"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::MigrationRisk) do
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
    conn.stub_columns_for("users", [])
    conn.stub_indexes_for("users", [])
    conn.stub_primary_key("users", "id")
    conn
  end

  it "extracts table names from a Rails migration and includes their schema" do
    expect(client).to(receive(:chat)) do |messages:|
      user = messages[1][:content]
      expect(user).to(include("Migration:"))
      expect(user).to(include("add_index"))
      expect(user).to(include("Table: users"))
    end.and_return({ "risk_level" => "low", "assessment" => "safe" })
    builder.call("add_index :users, :email, unique: true")
  end

  it "extracts table names from raw ALTER TABLE SQL" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages[1][:content]).to(include("Table: users"))
    end.and_return({ "risk_level" => "low", "assessment" => "ok" })
    builder.call("ALTER TABLE users ADD COLUMN archived_at DATETIME")
  end
end
