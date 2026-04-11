# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/describe_query"

RSpec.describe(MysqlGenius::Core::Ai::DescribeQuery) do
  subject(:builder) { described_class.new(client, config) }

  let(:client) { instance_double(MysqlGenius::Core::Ai::Client) }
  let(:config) do
    MysqlGenius::Core::Ai::Config.new(
      client: "openai",
      endpoint: "http://localhost/ai",
      api_key: "test-key",
      model: "gpt-4",
      auth_style: :bearer,
      system_context: "",
      domain_context: "Domain: Ruby on Rails application.",
    )
  end

  it "sends a chat request with system + user messages" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages).to(be_an(Array))
      expect(messages.size).to(eq(2))
      expect(messages[0][:role]).to(eq("system"))
      expect(messages[1][:role]).to(eq("user"))
    end.and_return({ "explanation" => "canned" })
    builder.call("SELECT 1")
  end

  it "interpolates config.domain_context into the system prompt" do
    allow(client).to(receive(:chat)) do |messages:|
      system = messages[0][:content]
      expect(system).to(include("Ruby on Rails application"))
    end.and_return({ "explanation" => "canned" })
    builder.call("SELECT 1")
  end

  it "passes the SQL as the user message content" do
    allow(client).to(receive(:chat)) do |messages:|
      expect(messages[1][:content]).to(eq("SELECT email FROM users"))
    end.and_return({ "explanation" => "canned" })
    builder.call("SELECT email FROM users")
  end

  it "returns whatever Core::Ai::Client returns" do
    allow(client).to(receive(:chat).and_return({ "explanation" => "a plain-English explanation" }))
    result = builder.call("SELECT 1")
    expect(result).to(eq({ "explanation" => "a plain-English explanation" }))
  end
end
