# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/index_advisor"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::IndexAdvisor) do
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

  it "composes a prompt containing SQL, EXPLAIN rows, and schema with cardinality" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("Query:"))
      expect(user_content).to(include("SELECT id FROM users"))
      expect(user_content).to(include("EXPLAIN:"))
    end.and_return({ "indexes" => "CREATE INDEX ..." })
    builder.call("SELECT id FROM users", [["1", "SIMPLE", "users", "ALL"]])
  end
end
