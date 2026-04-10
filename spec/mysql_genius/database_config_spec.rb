# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/database_config"

RSpec.describe(MysqlGenius::DatabaseConfig) do
  let(:global_config) do
    MysqlGenius::Configuration.new
  end

  describe "#initialize" do
    it "stores the key and global config" do
      db_config = described_class.new(:primary, global_config)
      expect(db_config.key).to(eq(:primary))
    end

    it "defaults label to titleized key" do
      db_config = described_class.new(:analytics_warehouse, global_config)
      expect(db_config.label).to(eq("Analytics warehouse"))
    end
  end

  describe "per-database overrides" do
    it "returns its own value when set" do
      db_config = described_class.new(:primary, global_config)
      db_config.blocked_tables = ["raw_events"]
      expect(db_config.blocked_tables).to(eq(["raw_events"]))
    end

    it "falls back to global config when not set" do
      global_config.blocked_tables = ["sessions", "schema_migrations"]
      db_config = described_class.new(:primary, global_config)
      expect(db_config.blocked_tables).to(eq(["sessions", "schema_migrations"]))
    end

    it "supports overriding table and column settings" do
      db_config = described_class.new(:primary, global_config)
      db_config.masked_column_patterns = ["ssn"]
      db_config.featured_tables = ["users"]
      db_config.default_columns = { "users" => ["id", "name"] }

      expect(db_config.masked_column_patterns).to(eq(["ssn"]))
      expect(db_config.featured_tables).to(eq(["users"]))
      expect(db_config.default_columns).to(eq({ "users" => ["id", "name"] }))
    end

    it "supports overriding row limit and timeout settings" do
      db_config = described_class.new(:primary, global_config)
      db_config.max_row_limit = 500
      db_config.default_row_limit = 10
      db_config.query_timeout_ms = 5000

      expect(db_config.max_row_limit).to(eq(500))
      expect(db_config.default_row_limit).to(eq(10))
      expect(db_config.query_timeout_ms).to(eq(5000))
    end
  end

  describe "#load_from_yaml" do
    it "loads settings from a hash" do
      db_config = described_class.new(:primary, global_config)
      db_config.load_from_yaml(
        "label" => "Main App",
        "blocked_tables" => ["raw_events"],
        "query_timeout_ms" => 60_000,
      )

      expect(db_config.label).to(eq("Main App"))
      expect(db_config.blocked_tables).to(eq(["raw_events"]))
      expect(db_config.query_timeout_ms).to(eq(60_000))
    end

    it "ignores unknown keys" do
      db_config = described_class.new(:primary, global_config)
      expect { db_config.load_from_yaml("unknown_key" => "value") }.not_to(raise_error)
    end
  end
end
