# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Connection::FakeAdapter) do
  subject(:adapter) { described_class.new }

  describe "#exec_query" do
    it "returns stubbed results matching a regex" do
      adapter.stub_query(
        /SELECT .* FROM users/i,
        columns: ["id", "name"],
        rows: [[1, "Alice"]],
      )

      result = adapter.exec_query("SELECT id, name FROM users")

      expect(result).to(be_a(MysqlGenius::Core::Result))
      expect(result.columns).to(eq(["id", "name"]))
      expect(result.rows).to(eq([[1, "Alice"]]))
    end

    it "raises when no stub matches" do
      expect { adapter.exec_query("SELECT 1") }.to(
        raise_error(MysqlGenius::Core::Connection::FakeAdapter::NoStubError, /No stub matched/),
      )
    end

    it "matches stubs in the order they were registered" do
      adapter.stub_query(/FROM users/, columns: ["a"], rows: [[1]])
      adapter.stub_query(/FROM users/, columns: ["b"], rows: [[2]])

      expect(adapter.exec_query("SELECT * FROM users").rows).to(eq([[1]]))
    end

    it "allows a stub to raise an error" do
      adapter.stub_query(/FROM users/, raises: StandardError.new("boom"))

      expect { adapter.exec_query("SELECT * FROM users") }.to(raise_error(StandardError, "boom"))
    end
  end

  describe "#select_value" do
    it "returns the first value of the first row of a stubbed query" do
      adapter.stub_query(/VERSION/, columns: ["VERSION()"], rows: [["8.0.35"]])

      expect(adapter.select_value("SELECT VERSION()")).to(eq("8.0.35"))
    end

    it "returns nil when the result is empty" do
      adapter.stub_query(/SELECT/, columns: ["x"], rows: [])

      expect(adapter.select_value("SELECT x FROM empty_table")).to(be_nil)
    end
  end

  describe "#server_version" do
    it "returns a ServerInfo built from a stubbed version" do
      adapter.stub_server_version("8.0.35")

      info = adapter.server_version
      expect(info).to(be_a(MysqlGenius::Core::ServerInfo))
      expect(info.vendor).to(eq(:mysql))
      expect(info.version).to(eq("8.0.35"))
    end

    it "detects MariaDB" do
      adapter.stub_server_version("10.11.5-MariaDB")

      expect(adapter.server_version.vendor).to(eq(:mariadb))
    end
  end

  describe "#current_database" do
    it "returns the stubbed database name" do
      adapter.stub_current_database("app_production")

      expect(adapter.current_database).to(eq("app_production"))
    end
  end

  describe "#quote" do
    it "wraps strings in single quotes" do
      expect(adapter.quote("hello")).to(eq("'hello'"))
    end

    it "escapes embedded single quotes" do
      expect(adapter.quote("O'Brien")).to(eq("'O''Brien'"))
    end

    it "returns integers as their decimal representation" do
      expect(adapter.quote(42)).to(eq("42"))
    end

    it "returns NULL for nil" do
      expect(adapter.quote(nil)).to(eq("NULL"))
    end
  end

  describe "#quote_table_name" do
    it "wraps an identifier in backticks" do
      expect(adapter.quote_table_name("users")).to(eq("`users`"))
    end
  end

  describe "#tables" do
    it "returns the stubbed table list" do
      adapter.stub_tables(["users", "posts"])

      expect(adapter.tables).to(eq(["users", "posts"]))
    end

    it "returns an empty array by default" do
      expect(adapter.tables).to(eq([]))
    end
  end

  describe "#columns_for" do
    it "returns the stubbed columns for a table" do
      col = MysqlGenius::Core::ColumnDefinition.new(
        name: "id", type: :integer, sql_type: "bigint", null: false, default: nil, primary_key: true,
      )
      adapter.stub_columns_for("users", [col])

      expect(adapter.columns_for("users")).to(eq([col]))
    end

    it "returns an empty array for unknown tables" do
      expect(adapter.columns_for("unknown")).to(eq([]))
    end
  end

  describe "#indexes_for" do
    it "returns the stubbed indexes for a table" do
      idx = MysqlGenius::Core::IndexDefinition.new(name: "idx_a", columns: ["a"], unique: true)
      adapter.stub_indexes_for("users", [idx])

      expect(adapter.indexes_for("users")).to(eq([idx]))
    end

    it "returns an empty array for unknown tables" do
      expect(adapter.indexes_for("unknown")).to(eq([]))
    end
  end

  describe "#primary_key" do
    it "returns the stubbed primary key for a table" do
      adapter.stub_primary_key("users", "id")

      expect(adapter.primary_key("users")).to(eq("id"))
    end

    it "returns nil by default" do
      expect(adapter.primary_key("x")).to(be_nil)
    end
  end

  describe "#close" do
    it "is a no-op that returns nil" do
      expect(adapter.close).to(be_nil)
    end
  end
end
