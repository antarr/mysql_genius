# frozen_string_literal: true

require "spec_helper"
require "trilogy"
require "mysql_genius/core/connection/trilogy_adapter"

RSpec.describe(MysqlGenius::Core::Connection::TrilogyAdapter) do
  let(:client) { instance_double(Trilogy) }
  let(:adapter) { described_class.new(client) }

  describe "#exec_query" do
    it "returns a Core::Result wrapping Trilogy's fields and rows" do
      trilogy_result = instance_double(
        Trilogy::Result,
        fields: ["id", "name"],
        rows:   [[1, "alice"], [2, "bob"]],
      )
      allow(client).to(receive(:query).with("SELECT id, name FROM users").and_return(trilogy_result))

      result = adapter.exec_query("SELECT id, name FROM users")
      expect(result).to(be_a(MysqlGenius::Core::Result))
      expect(result.columns).to(eq(["id", "name"]))
      expect(result.rows).to(eq([[1, "alice"], [2, "bob"]]))
    end
  end

  describe "#select_value" do
    it "returns the first cell of the first row" do
      trilogy_result = instance_double(Trilogy::Result, fields: ["v"], rows: [["8.0.35"]])
      allow(client).to(receive(:query).with("SELECT VERSION()").and_return(trilogy_result))
      expect(adapter.select_value("SELECT VERSION()")).to(eq("8.0.35"))
    end

    it "returns nil when the result has no rows" do
      trilogy_result = instance_double(Trilogy::Result, fields: ["v"], rows: [])
      allow(client).to(receive(:query).with("SELECT DATABASE()").and_return(trilogy_result))
      expect(adapter.select_value("SELECT DATABASE()")).to(be_nil)
    end
  end

  describe "#server_version" do
    it "returns a parsed Core::ServerInfo" do
      trilogy_result = instance_double(Trilogy::Result, fields: ["v"], rows: [["8.0.35"]])
      allow(client).to(receive(:query).with("SELECT VERSION()").and_return(trilogy_result))
      info = adapter.server_version
      expect(info).to(be_a(MysqlGenius::Core::ServerInfo))
      expect(info.mariadb?).to(be(false))
    end
  end

  describe "#current_database" do
    it "returns the database name from SELECT DATABASE()" do
      trilogy_result = instance_double(Trilogy::Result, fields: ["DATABASE()"], rows: [["app_dev"]])
      allow(client).to(receive(:query).with("SELECT DATABASE()").and_return(trilogy_result))
      expect(adapter.current_database).to(eq("app_dev"))
    end
  end

  describe "#quote" do
    it "wraps values in single quotes and delegates escaping to the client" do
      allow(client).to(receive(:escape).with("o'brien").and_return("o\\'brien"))
      expect(adapter.quote("o'brien")).to(eq("'o\\'brien'"))
    end
  end

  describe "#quote_table_name" do
    it "backtick-quotes identifiers and escapes embedded backticks" do
      expect(adapter.quote_table_name("users")).to(eq("`users`"))
      expect(adapter.quote_table_name("weird`name")).to(eq("`weird``name`"))
    end
  end

  describe "#tables" do
    it "queries information_schema.TABLES scoped to the current database" do
      database_result = instance_double(Trilogy::Result, fields: ["DATABASE()"], rows: [["app_dev"]])
      tables_result = instance_double(
        Trilogy::Result,
        fields: ["TABLE_NAME"],
        rows:   [["orders"], ["products"], ["users"]],
      )
      allow(client).to(receive(:query).with("SELECT DATABASE()").and_return(database_result))
      allow(client).to(receive(:escape).with("app_dev").and_return("app_dev"))
      allow(client).to(receive(:query)
        .with(a_string_matching(/information_schema\.TABLES.*'app_dev'.*BASE TABLE.*ORDER BY TABLE_NAME/m))
        .and_return(tables_result))
      expect(adapter.tables).to(eq(["orders", "products", "users"]))
    end
  end

  describe "#columns_for" do
    it "returns Core::ColumnDefinition objects built from information_schema.COLUMNS" do
      database_result = instance_double(Trilogy::Result, fields: ["DATABASE()"], rows: [["app_dev"]])
      columns_result = instance_double(
        Trilogy::Result,
        fields: ["COLUMN_NAME", "COLUMN_TYPE", "DATA_TYPE", "IS_NULLABLE", "COLUMN_DEFAULT", "COLUMN_KEY"],
        rows:   [
          ["id",    "bigint(20)",   "bigint", "NO", nil, "PRI"],
          ["email", "varchar(255)", "varchar", "NO", nil, ""],
        ],
      )
      allow(client).to(receive(:query).with("SELECT DATABASE()").and_return(database_result))
      allow(client).to(receive(:escape).with("app_dev").and_return("app_dev"))
      allow(client).to(receive(:escape).with("users").and_return("users"))
      allow(client).to(receive(:query)
        .with(a_string_matching(/information_schema\.COLUMNS.*'app_dev'.*'users'.*ORDER BY ORDINAL_POSITION/m))
        .and_return(columns_result))

      cols = adapter.columns_for("users")
      expect(cols.map(&:name)).to(eq(["id", "email"]))
      expect(cols.first).to(be_a(MysqlGenius::Core::ColumnDefinition))
      expect(cols.first.primary_key).to(be(true))
      expect(cols.first.null).to(be(false))
      expect(cols.last.primary_key).to(be(false))
    end
  end

  describe "#indexes_for" do
    it "groups information_schema.STATISTICS rows by index name into Core::IndexDefinition" do
      database_result = instance_double(Trilogy::Result, fields: ["DATABASE()"], rows: [["app_dev"]])
      stats_result = instance_double(
        Trilogy::Result,
        fields: ["INDEX_NAME", "COLUMN_NAME", "SEQ_IN_INDEX", "NON_UNIQUE"],
        rows:   [
          ["PRIMARY",     "id",    1, 0],
          ["index_email", "email", 1, 0],
          ["idx_compound", "a",    1, 1],
          ["idx_compound", "b",    2, 1],
        ],
      )
      allow(client).to(receive(:query).with("SELECT DATABASE()").and_return(database_result))
      allow(client).to(receive(:escape).with("app_dev").and_return("app_dev"))
      allow(client).to(receive(:escape).with("users").and_return("users"))
      allow(client).to(receive(:query)
        .with(a_string_matching(/information_schema\.STATISTICS.*'app_dev'.*'users'.*ORDER BY INDEX_NAME, SEQ_IN_INDEX/m))
        .and_return(stats_result))

      indexes = adapter.indexes_for("users")
      expect(indexes.map(&:name)).to(eq(["PRIMARY", "idx_compound", "index_email"]))
      compound = indexes.find { |i| i.name == "idx_compound" }
      expect(compound.columns).to(eq(["a", "b"]))
      expect(compound.unique).to(be(false))
      expect(indexes.find { |i| i.name == "PRIMARY" }.unique).to(be(true))
    end
  end

  describe "#primary_key" do
    it "returns the first column of the PRIMARY index, or nil if missing" do
      database_result = instance_double(Trilogy::Result, fields: ["DATABASE()"], rows: [["app_dev"]])
      pk_result = instance_double(
        Trilogy::Result,
        fields: ["COLUMN_NAME"],
        rows:   [["id"]],
      )
      allow(client).to(receive(:query).with("SELECT DATABASE()").and_return(database_result))
      allow(client).to(receive(:escape).with("app_dev").and_return("app_dev"))
      allow(client).to(receive(:escape).with("users").and_return("users"))
      allow(client).to(receive(:query)
        .with(a_string_matching(/information_schema\.KEY_COLUMN_USAGE.*'app_dev'.*'users'.*PRIMARY.*ORDINAL_POSITION = 1/m))
        .and_return(pk_result))
      expect(adapter.primary_key("users")).to(eq("id"))
    end

    it "returns nil when there is no primary key" do
      database_result = instance_double(Trilogy::Result, fields: ["DATABASE()"], rows: [["app_dev"]])
      empty_result = instance_double(Trilogy::Result, fields: ["COLUMN_NAME"], rows: [])
      allow(client).to(receive(:query).with("SELECT DATABASE()").and_return(database_result))
      allow(client).to(receive(:escape).with("app_dev").and_return("app_dev"))
      allow(client).to(receive(:escape).with("sessions").and_return("sessions"))
      allow(client).to(receive(:query)
        .with(a_string_matching(/information_schema\.KEY_COLUMN_USAGE.*'sessions'/m))
        .and_return(empty_result))
      expect(adapter.primary_key("sessions")).to(be_nil)
    end
  end

  describe "#close" do
    it "closes the underlying Trilogy client and returns nil" do
      allow(client).to(receive(:close))
      expect(adapter.close).to(be_nil)
      expect(client).to(have_received(:close))
    end
  end
end
