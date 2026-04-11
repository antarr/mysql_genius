# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Ai::Suggestion) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:ai_config) do
    MysqlGenius::Core::Ai::Config.new(
      client: lambda { |**_kwargs| { "sql" => "SELECT id FROM users", "explanation" => "returns all user ids" } },
      endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
    )
  end
  let(:client) { MysqlGenius::Core::Ai::Client.new(ai_config) }

  subject(:service) { described_class.new(connection, client, ai_config) }

  before do
    connection.stub_tables(["users", "posts"])
    connection.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", type: :integer, sql_type: "bigint", null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email", type: :string, sql_type: "varchar(255)", null: false, default: nil, primary_key: false),
    ])
  end

  describe "#call" do
    it "returns the AI result for an allowed table" do
      result = service.call("Show me all users", ["users"])
      expect(result).to(eq({ "sql" => "SELECT id FROM users", "explanation" => "returns all user ids" }))
    end

    it "builds a schema description from the connection" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "sql" => "", "explanation" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call("prompt", ["users"])

      system_message = captured_messages.find { |m| m[:role] == "system" }
      expect(system_message[:content]).to(include("users: id (integer), email (string)"))
    end

    it "skips tables that aren't in connection.tables" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "sql" => "", "explanation" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call("prompt", ["users", "not_a_real_table"])

      system_message = captured_messages.find { |m| m[:role] == "system" }
      expect(system_message[:content]).not_to(include("not_a_real_table"))
    end

    it "includes the system context when provided" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "sql" => "", "explanation" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: "Healthcare app with HIPAA constraints",
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call("prompt", ["users"])

      system_message = captured_messages.find { |m| m[:role] == "system" }
      expect(system_message[:content]).to(include("Healthcare app with HIPAA constraints"))
    end
  end
end
