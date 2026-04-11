# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Ai::Optimization) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:ai_config) do
    MysqlGenius::Core::Ai::Config.new(
      client: lambda { |**_kwargs| { "suggestions" => "Add an index on `users.email`" } },
      endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
    )
  end
  let(:client) { MysqlGenius::Core::Ai::Client.new(ai_config) }

  subject(:service) { described_class.new(connection, client, ai_config) }

  before do
    connection.stub_tables(["users"])
    connection.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", type: :integer, sql_type: "bigint", null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email", type: :string, sql_type: "varchar(255)", null: false, default: nil, primary_key: false),
    ])
    connection.stub_indexes_for("users", [
      MysqlGenius::Core::IndexDefinition.new(name: "users_pkey", columns: ["id"], unique: true),
    ])
  end

  describe "#call" do
    it "returns the AI result" do
      result = service.call("SELECT * FROM users WHERE email = 'x'", [["1", "SIMPLE", "users", "ALL"]], ["users"])
      expect(result).to(eq({ "suggestions" => "Add an index on `users.email`" }))
    end

    it "includes both columns and indexes in the schema description" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "suggestions" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call("SELECT * FROM users", [], ["users"])

      system_message = captured_messages.find { |m| m[:role] == "system" }
      expect(system_message[:content]).to(include("users: id (integer), email (string)"))
      expect(system_message[:content]).to(include("users_pkey: [id] UNIQUE"))
    end

    it "formats EXPLAIN rows from an array" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "suggestions" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call(
        "SELECT * FROM users",
        [["1", "SIMPLE", "users", "ALL", "10"]],
        ["users"],
      )

      user_message = captured_messages.find { |m| m[:role] == "user" }
      expect(user_message[:content]).to(include("1 | SIMPLE | users | ALL | 10"))
    end

    it "passes through EXPLAIN output already formatted as a string" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "suggestions" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call(
        "SELECT * FROM users",
        "pre-formatted explain output",
        ["users"],
      )

      user_message = captured_messages.find { |m| m[:role] == "user" }
      expect(user_message[:content]).to(include("pre-formatted explain output"))
    end
  end
end
