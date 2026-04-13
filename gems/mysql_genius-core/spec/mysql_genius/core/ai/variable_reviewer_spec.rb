# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/variable_reviewer"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::VariableReviewer) do
  subject(:reviewer) { described_class.new(client, config, connection) }

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
    conn.stub_query(
      /SHOW GLOBAL VARIABLES/i,
      columns: ["Variable_name", "Value"],
      rows: [
        ["innodb_buffer_pool_size", "134217728"],
        ["max_connections", "151"],
        ["slow_query_log", "ON"],
        ["long_query_time", "10"],
      ],
    )
    conn.stub_query(
      /SHOW GLOBAL STATUS/i,
      columns: ["Variable_name", "Value"],
      rows: [
        ["Innodb_buffer_pool_reads", "1000"],
        ["Innodb_buffer_pool_read_requests", "500000"],
        ["Max_used_connections", "45"],
        ["Uptime", "86400"],
      ],
    )
    conn
  end

  it "sends system and user messages to the AI client" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages.length).to(eq(2))
      expect(messages[0][:role]).to(eq("system"))
      expect(messages[1][:role]).to(eq("user"))
    end.and_return({ "findings" => "all good" })
    reviewer.call
  end

  it "includes relevant variables in the user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("innodb_buffer_pool_size"))
      expect(user_content).to(include("max_connections"))
      expect(user_content).to(include("slow_query_log"))
    end.and_return({ "findings" => "all good" })
    reviewer.call
  end

  it "includes status counters in the user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("Innodb_buffer_pool_reads"))
      expect(user_content).to(include("Max_used_connections"))
      expect(user_content).to(include("Uptime"))
    end.and_return({ "findings" => "all good" })
    reviewer.call
  end

  it "interpolates domain_context into the system prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages[0][:content]).to(include("This is a Rails app"))
    end.and_return({ "findings" => "all good" })
    reviewer.call
  end

  it "returns the parsed AI response" do
    allow(client).to(receive(:chat).and_return({ "findings" => "increase buffer pool" }))
    result = reviewer.call
    expect(result).to(eq({ "findings" => "increase buffer pool" }))
  end
end
