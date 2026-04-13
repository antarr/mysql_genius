# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/innodb_interpreter"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::InnodbInterpreter) do
  subject(:interpreter) { described_class.new(client, config, connection) }

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
  let(:innodb_status_text) { "=====================================\n2026-04-13 INNODB MONITOR OUTPUT\n=====================================\nBUFFER POOL AND MEMORY\n---\nTotal large memory allocated 137428992\nDictionary memory allocated 776332\nBuffer pool size   8191\nFree buffers       1024\nDatabase pages     7167\nModified db pages  42\nPending reads      0\nPending writes: LRU 0, flush list 0, single page 0\n---\nSEMAPHORES\nOS WAIT ARRAY INFO: reservation count 15\nMutex spin waits 20, rounds 200, OS waits 5\n---\nLATEST DETECTED DEADLOCK\nNone\n---\nTRANSACTIONS\nHistory list length 156\n" }
  let(:connection) do
    conn = MysqlGenius::Core::Connection::FakeAdapter.new
    conn.stub_query(
      /SHOW ENGINE INNODB STATUS/i,
      columns: ["Type", "Name", "Status"],
      rows: [["InnoDB", "", innodb_status_text]],
    )
    conn.stub_query(
      /SHOW GLOBAL STATUS/i,
      columns: ["Variable_name", "Value"],
      rows: [
        ["Innodb_buffer_pool_read_requests", "500000"],
        ["Innodb_buffer_pool_reads", "1000"],
        ["Innodb_buffer_pool_pages_dirty", "42"],
        ["Innodb_buffer_pool_pages_free", "1024"],
        ["Innodb_buffer_pool_pages_total", "8191"],
        ["Innodb_row_lock_waits", "5"],
        ["Innodb_row_lock_time", "150"],
        ["Threads_connected", "10"],
        ["Threads_running", "2"],
        ["Threads_cached", "5"],
        ["Threads_created", "100"],
        ["Aborted_connects", "0"],
        ["Aborted_clients", "0"],
        ["Max_used_connections", "20"],
        ["Questions", "100000"],
        ["Slow_queries", "50"],
        ["Created_tmp_tables", "1000"],
        ["Created_tmp_disk_tables", "100"],
        ["Select_full_join", "10"],
        ["Sort_merge_passes", "5"],
        ["Uptime", "86400"],
      ],
    )
    conn.stub_query(
      /SHOW GLOBAL VARIABLES/i,
      columns: ["Variable_name", "Value"],
      rows: [
        ["innodb_buffer_pool_size", "134217728"],
        ["max_connections", "151"],
      ],
    )
    conn.stub_query(
      /SELECT VERSION/i,
      columns: ["VERSION()"],
      rows: [["8.0.32"]],
    )
    conn
  end

  it "sends system and user messages to the AI client" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages.length).to(eq(2))
      expect(messages[0][:role]).to(eq("system"))
      expect(messages[1][:role]).to(eq("user"))
    end.and_return({ "findings" => "all good" })
    interpreter.call
  end

  it "includes InnoDB status text in the user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("INNODB MONITOR OUTPUT"))
      expect(user_content).to(include("BUFFER POOL AND MEMORY"))
    end.and_return({ "findings" => "all good" })
    interpreter.call
  end

  it "includes InnoDB metrics summary in the user prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      user_content = messages[1][:content]
      expect(user_content).to(include("Buffer Pool Hit Rate:"))
      expect(user_content).to(include("Dirty Pages:"))
      expect(user_content).to(include("Row Lock Waits:"))
    end.and_return({ "findings" => "all good" })
    interpreter.call
  end

  it "interpolates domain_context into the system prompt" do
    expect(client).to(receive(:chat)) do |messages:|
      expect(messages[0][:content]).to(include("This is a Rails app"))
    end.and_return({ "findings" => "all good" })
    interpreter.call
  end

  it "returns the parsed AI response" do
    allow(client).to(receive(:chat).and_return({ "findings" => "InnoDB looks healthy" }))
    result = interpreter.call
    expect(result).to(eq({ "findings" => "InnoDB looks healthy" }))
  end
end
