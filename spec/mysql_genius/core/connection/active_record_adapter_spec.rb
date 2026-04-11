# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core/connection/active_record_adapter"

RSpec.describe(MysqlGenius::Core::Connection::ActiveRecordAdapter) do
  subject(:adapter) { described_class.new(ar_connection) }

  let(:ar_connection) { double("ActiveRecord::Base.connection") }

  describe "#exec_query" do
    it "wraps an ActiveRecord::Result in a Core::Result" do
      ar_result = double("ActiveRecord::Result", columns: ["id", "name"], rows: [[1, "Alice"], [2, "Bob"]])
      allow(ar_connection).to(receive(:exec_query).with("SELECT id, name FROM users").and_return(ar_result))

      result = adapter.exec_query("SELECT id, name FROM users")

      expect(result).to(be_a(MysqlGenius::Core::Result))
      expect(result.columns).to(eq(["id", "name"]))
      expect(result.rows).to(eq([[1, "Alice"], [2, "Bob"]]))
    end
  end

  describe "#select_value" do
    it "delegates to the underlying connection" do
      allow(ar_connection).to(receive(:select_value).with("SELECT VERSION()").and_return("8.0.35"))

      expect(adapter.select_value("SELECT VERSION()")).to(eq("8.0.35"))
    end
  end

  describe "#server_version" do
    it "parses the version from SELECT VERSION()" do
      allow(ar_connection).to(receive(:select_value).with("SELECT VERSION()").and_return("8.0.35"))

      info = adapter.server_version
      expect(info.vendor).to(eq(:mysql))
      expect(info.version).to(eq("8.0.35"))
    end

    it "detects MariaDB" do
      allow(ar_connection).to(receive(:select_value).with("SELECT VERSION()").and_return("10.11.5-MariaDB"))

      expect(adapter.server_version.vendor).to(eq(:mariadb))
    end
  end

  describe "#current_database" do
    it "delegates" do
      allow(ar_connection).to(receive(:current_database).and_return("app_production"))

      expect(adapter.current_database).to(eq("app_production"))
    end
  end

  describe "#quote" do
    it "delegates" do
      allow(ar_connection).to(receive(:quote).with("hello").and_return("'hello'"))

      expect(adapter.quote("hello")).to(eq("'hello'"))
    end
  end

  describe "#quote_table_name" do
    it "delegates" do
      allow(ar_connection).to(receive(:quote_table_name).with("users").and_return("`users`"))

      expect(adapter.quote_table_name("users")).to(eq("`users`"))
    end
  end

  describe "#tables" do
    it "delegates" do
      allow(ar_connection).to(receive(:tables).and_return(["users", "posts"]))

      expect(adapter.tables).to(eq(["users", "posts"]))
    end
  end

  describe "#columns_for" do
    it "maps AR::ConnectionAdapters::Column instances to Core::ColumnDefinition" do
      ar_col = double(
        "AR column",
        name: "email",
        type: :string,
        sql_type: "varchar(255)",
        null: false,
        default: nil,
      )
      allow(ar_connection).to(receive(:columns).with("users").and_return([ar_col]))
      allow(ar_connection).to(receive(:primary_key).with("users").and_return("id"))

      columns = adapter.columns_for("users")

      expect(columns.length).to(eq(1))
      expect(columns.first).to(be_a(MysqlGenius::Core::ColumnDefinition))
      expect(columns.first.name).to(eq("email"))
      expect(columns.first.type).to(eq(:string))
      expect(columns.first.sql_type).to(eq("varchar(255)"))
      expect(columns.first.null).to(be(false))
      expect(columns.first.primary_key).to(be(false))
    end

    it "marks the primary key column correctly" do
      pk_col = double("AR column", name: "id", type: :integer, sql_type: "bigint", null: false, default: nil)
      allow(ar_connection).to(receive(:columns).with("users").and_return([pk_col]))
      allow(ar_connection).to(receive(:primary_key).with("users").and_return("id"))

      column = adapter.columns_for("users").first
      expect(column.primary_key?).to(be(true))
    end
  end

  describe "#indexes_for" do
    it "maps AR::ConnectionAdapters::IndexDefinition to Core::IndexDefinition" do
      ar_idx = double("AR index", name: "index_users_on_email", columns: ["email"], unique: true)
      allow(ar_connection).to(receive(:indexes).with("users").and_return([ar_idx]))

      indexes = adapter.indexes_for("users")

      expect(indexes.length).to(eq(1))
      expect(indexes.first).to(be_a(MysqlGenius::Core::IndexDefinition))
      expect(indexes.first.name).to(eq("index_users_on_email"))
      expect(indexes.first.columns).to(eq(["email"]))
      expect(indexes.first.unique).to(be(true))
    end
  end

  describe "#primary_key" do
    it "delegates" do
      allow(ar_connection).to(receive(:primary_key).with("users").and_return("id"))

      expect(adapter.primary_key("users")).to(eq("id"))
    end
  end

  describe "#close" do
    it "is a no-op (AR manages the pool)" do
      expect(adapter.close).to(be_nil)
    end
  end
end
