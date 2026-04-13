# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/workload_digest"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::WorkloadDigest) do
  subject(:digest) { described_class.new(connection, client, config) }

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
  let(:query_stats_result) do
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

  before do
    query_stats_instance = instance_double(MysqlGenius::Core::Analysis::QueryStats)
    allow(MysqlGenius::Core::Analysis::QueryStats).to(receive(:new).with(connection).and_return(query_stats_instance))
    allow(query_stats_instance).to(receive(:call).with(sort: "total_time", limit: 30).and_return(query_stats_result))
  end

  it "sends system and user messages to the AI client" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages.length).to(eq(2))
      expect(messages[0][:role]).to(eq("system"))
      expect(messages[1][:role]).to(eq("user"))
    end.and_return({ "digest" => "workload summary" })
    digest.call
  end

  it "includes query stats in the user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("SELECT `users`"))
      expect(user_content).to(include("calls=5000"))
      expect(user_content).to(include("avg_time_ms=2.4"))
      expect(user_content).to(include("rows_ratio=100.0"))
    end.and_return({ "digest" => "workload summary" })
    digest.call
  end

  it "includes tmp_disk_tables in formatted output" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("tmp_disk_tables=10"))
    end.and_return({ "digest" => "workload summary" })
    digest.call
  end

  it "interpolates domain_context into the system prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages[0][:content]).to(include("This is a Rails app"))
    end.and_return({ "digest" => "workload summary" })
    digest.call
  end

  it "returns the parsed AI response" do
    allow(client).to(receive(:chat).and_return({ "digest" => "80% reads, optimize orders table" }))
    result = digest.call
    expect(result).to(eq({ "digest" => "80% reads, optimize orders table" }))
  end
end
