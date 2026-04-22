# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/database_registry"

RSpec.describe(MysqlGenius::DatabaseRegistry) do
  let(:config) { MysqlGenius::Configuration.new }

  def fake_config(name:, adapter: "mysql2", replica: false)
    double(
      "DbConfig:#{name}",
      name: name,
      adapter: adapter,
      replica?: replica,
      configuration_hash: { adapter: adapter, database: name, host: "localhost", replica: replica },
    )
  end

  def discover(configs, env: "test", config_override: config)
    configurations = double("Configurations", configs_for: configs)
    described_class.discover(configurations: configurations, env: env, config: config_override)
  end

  describe "adapter filtering" do
    it "discovers mysql2 configs" do
      registry = discover([fake_config(name: "primary", adapter: "mysql2")])
      expect(registry.keys).to(eq(["primary"]))
    end

    it "discovers trilogy configs" do
      registry = discover([fake_config(name: "primary", adapter: "trilogy")])
      expect(registry.keys).to(eq(["primary"]))
    end

    it "skips non-MySQL adapters" do
      registry = discover([
        fake_config(name: "primary", adapter: "mysql2"),
        fake_config(name: "cache", adapter: "postgresql"),
        fake_config(name: "bg", adapter: "sqlite3"),
      ])
      expect(registry.keys).to(eq(["primary"]))
    end

    it "is empty when no MySQL configs exist" do
      registry = discover([fake_config(name: "primary", adapter: "postgresql")])
      expect(registry.empty?).to(be(true))
      expect(registry.default_key).to(be_nil)
    end

    it "is empty when configurations is nil" do
      registry = described_class.discover(configurations: nil, env: "test", config: config)
      expect(registry.empty?).to(be(true))
    end
  end

  describe "writer/replica pairing" do
    it "pairs <name>_replica with <name>" do
      registry = discover([
        fake_config(name: "primary"),
        fake_config(name: "primary_replica", replica: true),
      ])
      expect(registry.keys).to(eq(["primary"]))
      expect(registry["primary"].reader?).to(be(true))
    end

    it "pairs <name>_reading with <name>" do
      registry = discover([
        fake_config(name: "primary"),
        fake_config(name: "primary_reading", replica: true),
      ])
      expect(registry["primary"].reader?).to(be(true))
    end

    it "treats configs with replica: true in the hash as readers even without replica? method" do
      writer = double("W", name: "primary", adapter: "mysql2", replica?: false,
        configuration_hash: { adapter: "mysql2" })
      replica = double("R", name: "primary_replica", adapter: "mysql2", replica?: false,
        configuration_hash: { adapter: "mysql2", replica: true })
      registry = discover([writer, replica])
      expect(registry.keys).to(eq(["primary"]))
      expect(registry["primary"].reader?).to(be(true))
    end

    it "treats unpaired readers as orphaned and does not surface them as tabs" do
      registry = discover([fake_config(name: "primary_replica", replica: true)])
      expect(registry.empty?).to(be(true))
    end

    it "surfaces multiple independent writers each with their own readers" do
      registry = discover([
        fake_config(name: "primary"),
        fake_config(name: "primary_replica", replica: true),
        fake_config(name: "analytics"),
        fake_config(name: "analytics_replica", replica: true),
      ])
      expect(registry.keys).to(contain_exactly("primary", "analytics"))
      expect(registry["primary"].reader?).to(be(true))
      expect(registry["analytics"].reader?).to(be(true))
    end
  end

  describe "allowlist / blocklist / default" do
    let(:configs) do
      [
        fake_config(name: "primary"),
        fake_config(name: "analytics"),
        fake_config(name: "shard_0"),
      ]
    end

    it "respects databases allowlist" do
      config.databases = %w[primary analytics]
      registry = discover(configs)
      expect(registry.keys).to(eq(["primary", "analytics"]))
    end

    it "respects exclude_databases blocklist" do
      config.exclude_databases = %w[shard_0]
      registry = discover(configs)
      expect(registry.keys).to(contain_exactly("primary", "analytics"))
    end

    it "allowlist ordering controls tab order" do
      config.databases = %w[shard_0 analytics primary]
      registry = discover(configs)
      expect(registry.keys).to(eq(["shard_0", "analytics", "primary"]))
    end

    it "default_key is first discovered when not configured" do
      registry = discover(configs)
      expect(registry.default_key).to(eq("primary"))
    end

    it "default_key honors default_database when set and valid" do
      config.default_database = "analytics"
      registry = discover(configs)
      expect(registry.default_key).to(eq("analytics"))
    end

    it "ignores default_database pointing at an unknown name" do
      config.default_database = "nonexistent"
      registry = discover(configs)
      expect(registry.default_key).to(eq("primary"))
    end

    it "applies database_labels" do
      config.database_labels = { "shard_0" => "US-East Shard" }
      registry = discover(configs)
      expect(registry["shard_0"].label).to(eq("US-East Shard"))
      expect(registry["primary"].label).to(eq("primary"))
    end
  end

  describe "URL collision avoidance" do
    it "prefixes reserved url segments with an underscore" do
      registry = discover([fake_config(name: "api")])
      expect(registry.keys).to(eq(["_api"]))
    end
  end

  describe "#fetch" do
    it "returns the matching database" do
      registry = discover([fake_config(name: "primary")])
      expect(registry.fetch("primary")).to(be_a(MysqlGenius::Database))
    end

    it "raises KeyError with known keys listed in the message" do
      registry = discover([fake_config(name: "primary")])
      expect { registry.fetch("nope") }.to(raise_error(KeyError, /primary/))
    end
  end
end
