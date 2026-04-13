# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/connection_advisor"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::ConnectionAdvisor) do
  subject(:advisor) { described_class.new(client, config, connection) }

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
        ["max_connections", "151"],
        ["wait_timeout", "28800"],
        ["interactive_timeout", "28800"],
        ["thread_cache_size", "9"],
      ],
    )
    conn.stub_query(
      /SHOW GLOBAL STATUS/i,
      columns: ["Variable_name", "Value"],
      rows: [
        ["Threads_connected", "12"],
        ["Threads_running", "3"],
        ["Max_used_connections", "45"],
        ["Aborted_connects", "5"],
        ["Aborted_clients", "2"],
        ["Connections", "10000"],
        ["Threads_created", "150"],
      ],
    )
    conn
  end

  it "sends system and user messages to the AI client" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages.length).to(eq(2))
      expect(messages[0][:role]).to(eq("system"))
      expect(messages[1][:role]).to(eq("user"))
    end.and_return({ "diagnosis" => "healthy" })
    advisor.call
  end

  it "includes connection variables in the user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("max_connections"))
      expect(user_content).to(include("wait_timeout"))
      expect(user_content).to(include("thread_cache_size"))
    end.and_return({ "diagnosis" => "healthy" })
    advisor.call
  end

  it "includes status counters in the user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("Threads_connected"))
      expect(user_content).to(include("Max_used_connections"))
      expect(user_content).to(include("Aborted_connects"))
    end.and_return({ "diagnosis" => "healthy" })
    advisor.call
  end

  it "interpolates domain_context into the system prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages[0][:content]).to(include("This is a Rails app"))
    end.and_return({ "diagnosis" => "healthy" })
    advisor.call
  end

  it "returns the parsed AI response" do
    allow(client).to(receive(:chat).and_return({ "diagnosis" => "reduce max_connections to 100" }))
    result = advisor.call
    expect(result).to(eq({ "diagnosis" => "reduce max_connections to 100" }))
  end
end
