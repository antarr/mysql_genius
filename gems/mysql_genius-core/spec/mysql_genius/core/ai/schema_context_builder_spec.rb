# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/ai/schema_context_builder"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Ai::SchemaContextBuilder) do
  let(:connection) do
    adapter = MysqlGenius::Core::Connection::FakeAdapter.new
    adapter.stub_tables(["users", "orders"])
    adapter.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id",    sql_type: "bigint",       type: :integer, null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email", sql_type: "varchar(255)", type: :string,  null: false, default: nil, primary_key: false),
    ])
    adapter.stub_indexes_for("users", [
      MysqlGenius::Core::IndexDefinition.new(name: "idx_users_email", columns: ["email"], unique: true),
    ])
    adapter.stub_primary_key("users", "id")
    adapter.stub_query(/information_schema\.tables.*users/i, columns: ["TABLE_ROWS"], rows: [[1000]])
    adapter
  end

  describe "#call with detail: :basic" do
    it "returns a formatted string with table name, row count, PK, columns, and indexes" do
      result = described_class.new(connection).call(["users"], detail: :basic)
      expect(result).to(include("Table: users"))
      expect(result).to(include("~1000 rows"))
      expect(result).to(include("Primary Key: id"))
      expect(result).to(include("Columns:"))
      expect(result).to(include("id bigint NOT NULL"))
      expect(result).to(include("email varchar(255) NOT NULL"))
      expect(result).to(include("Indexes:"))
      expect(result).to(include("UNIQUE INDEX idx_users_email (email)"))
    end

    it "omits tables that do not exist in the connection" do
      result = described_class.new(connection).call(["users", "missing_table"], detail: :basic)
      expect(result).to(include("Table: users"))
      expect(result).not_to(include("missing_table"))
    end

    it "joins multiple tables with double-newlines" do
      connection.stub_columns_for("orders", [
        MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
      ])
      connection.stub_indexes_for("orders", [])
      connection.stub_primary_key("orders", "id")
      connection.stub_query(/information_schema\.tables.*orders/i, columns: ["TABLE_ROWS"], rows: [[500]])
      result = described_class.new(connection).call(["users", "orders"], detail: :basic)
      expect(result).to(match(/Table: users.*\n\nTable: orders/m))
    end
  end

  describe "#call with detail: :with_cardinality" do
    it "appends STATISTICS cardinality for each index" do
      connection.stub_query(
        /information_schema\.STATISTICS.*users/i,
        columns: ["INDEX_NAME", "COLUMN_NAME", "CARDINALITY", "SEQ_IN_INDEX"],
        rows: [["idx_users_email", "email", 950, 1]],
      )
      result = described_class.new(connection).call(["users"], detail: :with_cardinality)
      expect(result).to(include("cardinality=950"))
    end
  end
end
