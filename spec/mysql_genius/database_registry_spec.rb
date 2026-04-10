# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/database_registry"

RSpec.describe(MysqlGenius::DatabaseRegistry) do
  let(:config) { MysqlGenius.configuration }

  describe ".load_yaml" do
    it "loads defaults from YAML hash", :aggregate_failures do
      yaml = {
        "defaults" => { "max_row_limit" => 2000, "blocked_tables" => ["internal"] },
        "databases" => {
          "primary" => { "label" => "Main App" },
          "analytics" => { "label" => "Analytics", "query_timeout_ms" => 60_000 },
        },
      }

      described_class.load_yaml(yaml, config)

      expect(config.max_row_limit).to(eq(2000))
      expect(config.blocked_tables).to(eq(["internal"]))
      expect(config.databases[:primary].label).to(eq("Main App"))
      expect(config.databases[:analytics].query_timeout_ms).to(eq(60_000))
    end

    it "handles exclude list" do
      yaml = {
        "databases" => {
          "primary" => { "label" => "Main" },
          "cache_db" => { "label" => "Cache" },
        },
        "exclude" => ["cache_db"],
      }

      described_class.load_yaml(yaml, config)

      expect(config.databases).to(have_key(:primary))
      expect(config.databases).not_to(have_key(:cache_db))
    end

    it "deep-merges environment override" do
      base = {
        "defaults" => { "max_row_limit" => 1000 },
        "databases" => {
          "primary" => { "label" => "Main" },
        },
      }
      env_override = {
        "defaults" => { "max_row_limit" => 500 },
        "databases" => {
          "primary" => { "query_timeout_ms" => 10_000 },
          "analytics" => { "label" => "Analytics" },
        },
      }

      described_class.load_yaml(described_class.deep_merge(base, env_override), config)

      expect(config.max_row_limit).to(eq(500))
      expect(config.databases[:primary].label).to(eq("Main"))
      expect(config.databases[:primary].query_timeout_ms).to(eq(10_000))
      expect(config.databases[:analytics].label).to(eq("Analytics"))
    end

    it "does nothing when yaml is nil" do
      expect { described_class.load_yaml(nil, config) }.not_to(raise_error)
      expect(config.databases).to(eq({}))
    end
  end

  describe ".deep_merge" do
    it "merges nested hashes recursively" do
      base = { "a" => { "b" => 1, "c" => 2 }, "d" => 3 }
      override = { "a" => { "b" => 10, "e" => 5 }, "f" => 6 }
      result = described_class.deep_merge(base, override)

      expect(result).to(eq({ "a" => { "b" => 10, "c" => 2, "e" => 5 }, "d" => 3, "f" => 6 }))
    end
  end

  describe ".detect_databases" do
    it "creates a default primary entry when no databases are configured" do
      described_class.detect_databases(config)

      expect(config.databases).to(have_key(:primary))
      expect(config.databases[:primary].label).to(eq("Primary"))
    end

    it "does not overwrite databases already configured via YAML or initializer" do
      config.database(:analytics) { |db| db.label = "My Analytics" }

      described_class.detect_databases(config)

      expect(config.databases[:analytics].label).to(eq("My Analytics"))
    end
  end

  describe ".multi_db?" do
    it "returns false when one or zero databases exist" do
      expect(described_class.multi_db?(config)).to(be(false))

      config.database(:primary) {}
      expect(described_class.multi_db?(config)).to(be(false))
    end

    it "returns true when multiple databases exist" do
      config.database(:primary) {}
      config.database(:analytics) {}
      expect(described_class.multi_db?(config)).to(be(true))
    end
  end

  describe ".default_key" do
    it "returns the first database key" do
      config.database(:primary) {}
      config.database(:analytics) {}
      expect(described_class.default_key(config)).to(eq(:primary))
    end

    it "returns :primary when no databases configured" do
      expect(described_class.default_key(config)).to(eq(:primary))
    end
  end
end
