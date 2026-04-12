# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/desktop/config/mysql_config"
require "mysql_genius/desktop/config/security_config"

RSpec.describe(MysqlGenius::Desktop::Config::SecurityConfig) do
  describe ".from_hash" do
    it "applies empty-array defaults for blocked_tables, masked_column_patterns, and default_columns" do
      config = described_class.from_hash({})
      expect(config.blocked_tables).to(eq([]))
      expect(config.masked_column_patterns).to(eq([]))
      expect(config.default_columns).to(eq({}))
    end

    it "honours explicit blocked_tables and masked_column_patterns arrays" do
      config = described_class.from_hash({
        "blocked_tables" => ["schema_migrations", "ar_internal_metadata"],
        "masked_column_patterns" => ["password", "token", "secret"],
      })
      expect(config.blocked_tables).to(eq(["schema_migrations", "ar_internal_metadata"]))
      expect(config.masked_column_patterns).to(eq(["password", "token", "secret"]))
    end

    it "honours default_columns hash keyed by table name" do
      config = described_class.from_hash({
        "default_columns" => { "users" => ["id", "email", "created_at"] },
      })
      expect(config.default_columns).to(eq({ "users" => ["id", "email", "created_at"] }))
    end

    it "coerces nil values to their empty defaults" do
      config = described_class.from_hash({
        "blocked_tables" => nil,
        "masked_column_patterns" => nil,
        "default_columns" => nil,
      })
      expect(config.blocked_tables).to(eq([]))
      expect(config.masked_column_patterns).to(eq([]))
      expect(config.default_columns).to(eq({}))
    end
  end
end
