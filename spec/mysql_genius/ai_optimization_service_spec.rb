# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/ai_client"
require "mysql_genius/ai_optimization_service"

RSpec.describe(MysqlGenius::AiOptimizationService) do
  subject(:service) { described_class.new }

  let(:connection) { double("connection", tables: ["users", "posts"]) }

  let(:columns_map) do
    {
      "users" => [double(name: "id", type: :integer), double(name: "email", type: :string)],
      "posts" => [double(name: "id", type: :integer), double(name: "user_id", type: :integer)],
    }
  end

  let(:indexes_map) do
    {
      "users" => [double(name: "index_users_on_email", columns: ["email"], unique: true)],
      "posts" => [double(name: "index_posts_on_user_id", columns: ["user_id"], unique: false)],
    }
  end

  before do
    MysqlGenius.configure do |c|
      c.ai_endpoint = "https://api.example.com/v1/chat/completions"
      c.ai_api_key = "sk-test"
      c.ai_auth_style = :bearer
    end

    allow(connection).to(receive(:columns) { |table| columns_map[table] || [] })
    allow(connection).to(receive(:indexes) { |table| indexes_map[table] || [] })
  end

  describe "#call" do
    let(:explain_rows) { [["1", "SIMPLE", "users", "ALL"], ["1", "SIMPLE", "posts", "ref"]] }
    let(:ai_response) { { "suggestions" => "Add an index on users.email" } }

    before do
      ai_client = instance_double(MysqlGenius::AiClient)
      allow(MysqlGenius::AiClient).to(receive(:new).and_return(ai_client))
      allow(ai_client).to(receive(:chat).and_return(ai_response))
    end

    it "returns suggestions from the AI" do
      result = service.call("SELECT * FROM users", explain_rows, ["users"], connection: connection)
      expect(result).to(eq(ai_response))
    end

    it "includes schema with indexes in the system prompt" do
      ai_client = instance_double(MysqlGenius::AiClient)
      allow(MysqlGenius::AiClient).to(receive(:new).and_return(ai_client))

      expect(ai_client).to(receive(:chat)) do |messages:|
        system_prompt = messages[0][:content]
        expect(system_prompt).to(include("users"))
        expect(system_prompt).to(include("index_users_on_email"))
        ai_response
      end

      service.call("SELECT * FROM users", explain_rows, ["users"], connection: connection)
    end

    it "includes the SQL and EXPLAIN output in the user prompt" do
      ai_client = instance_double(MysqlGenius::AiClient)
      allow(MysqlGenius::AiClient).to(receive(:new).and_return(ai_client))

      expect(ai_client).to(receive(:chat)) do |messages:|
        user_prompt = messages[1][:content]
        expect(user_prompt).to(include("SELECT * FROM users"))
        expect(user_prompt).to(include("SIMPLE"))
        ai_response
      end

      service.call("SELECT * FROM users", explain_rows, ["users"], connection: connection)
    end

    it "handles string explain rows" do
      ai_client = instance_double(MysqlGenius::AiClient)
      allow(MysqlGenius::AiClient).to(receive(:new).and_return(ai_client))

      expect(ai_client).to(receive(:chat)) do |messages:|
        user_prompt = messages[1][:content]
        expect(user_prompt).to(include("pre-formatted explain"))
        ai_response
      end

      service.call("SELECT 1", "pre-formatted explain", ["users"], connection: connection)
    end
  end
end
