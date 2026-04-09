# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/ai_client"
require "mysql_genius/ai_suggestion_service"

RSpec.describe(MysqlGenius::AiSuggestionService) do
  subject(:service) { described_class.new }

  let(:connection) { double("connection", tables: ["users", "posts", "comments"]) }

  let(:columns_map) do
    {
      "users" => [
        double(name: "id", type: :integer),
        double(name: "name", type: :string),
        double(name: "email", type: :string),
      ],
      "posts" => [
        double(name: "id", type: :integer),
        double(name: "title", type: :string),
        double(name: "user_id", type: :integer),
      ],
    }
  end

  before do
    MysqlGenius.configure do |c|
      c.ai_endpoint = "https://api.example.com/v1/chat/completions"
      c.ai_api_key = "sk-test"
      c.ai_model = "gpt-4o"
      c.ai_auth_style = :bearer
    end

    allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
    allow(connection).to(receive(:columns) { |table| columns_map[table] || [] })
  end

  describe "#call" do
    let(:ai_response) { { "sql" => "SELECT * FROM users", "explanation" => "Gets all users" } }

    before do
      ai_client = instance_double(MysqlGenius::AiClient)
      allow(MysqlGenius::AiClient).to(receive(:new).and_return(ai_client))
      allow(ai_client).to(receive(:chat).and_return(ai_response))
    end

    it "returns sql and explanation from the AI" do
      result = service.call("show me all users", ["users", "posts"])
      expect(result).to(eq(ai_response))
    end

    it "passes messages with system and user roles" do
      ai_client = instance_double(MysqlGenius::AiClient)
      allow(MysqlGenius::AiClient).to(receive(:new).and_return(ai_client))

      expect(ai_client).to(receive(:chat)) do |messages:|
        expect(messages.length).to(eq(2))
        expect(messages[0][:role]).to(eq("system"))
        expect(messages[1][:role]).to(eq("user"))
        expect(messages[1][:content]).to(eq("show me all users"))
        ai_response
      end

      service.call("show me all users", ["users", "posts"])
    end

    it "includes schema description in the system prompt" do
      ai_client = instance_double(MysqlGenius::AiClient)
      allow(MysqlGenius::AiClient).to(receive(:new).and_return(ai_client))

      expect(ai_client).to(receive(:chat)) do |messages:|
        system_prompt = messages[0][:content]
        expect(system_prompt).to(include("users"))
        expect(system_prompt).to(include("id (integer)"))
        expect(system_prompt).to(include("name (string)"))
        ai_response
      end

      service.call("test", ["users"])
    end

    it "includes custom domain context when configured" do
      MysqlGenius.configuration.ai_system_context = "This is an e-commerce DB"

      ai_client = instance_double(MysqlGenius::AiClient)
      allow(MysqlGenius::AiClient).to(receive(:new).and_return(ai_client))

      expect(ai_client).to(receive(:chat)) do |messages:|
        expect(messages[0][:content]).to(include("e-commerce DB"))
        ai_response
      end

      service.call("test", ["users"])
    end

    it "only includes tables that exist in the connection" do
      ai_client = instance_double(MysqlGenius::AiClient)
      allow(MysqlGenius::AiClient).to(receive(:new).and_return(ai_client))

      expect(ai_client).to(receive(:chat)) do |messages:|
        system_prompt = messages[0][:content]
        expect(system_prompt).not_to(include("nonexistent_table"))
        ai_response
      end

      service.call("test", ["users", "nonexistent_table"])
    end
  end
end
