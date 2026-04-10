# frozen_string_literal: true

RSpec.describe(MysqlGenius::Configuration) do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "has sensible blocked tables" do
      expect(config.blocked_tables).to(include("sessions", "schema_migrations"))
    end

    it "has default masked column patterns" do
      expect(config.masked_column_patterns).to(include("password", "token", "secret"))
    end

    it "defaults max_row_limit to 1000" do
      expect(config.max_row_limit).to(eq(1000))
    end

    it "defaults default_row_limit to 25" do
      expect(config.default_row_limit).to(eq(25))
    end

    it "defaults query_timeout_ms to 30000" do
      expect(config.query_timeout_ms).to(eq(30_000))
    end

    it "defaults slow_query_threshold_ms to 250" do
      expect(config.slow_query_threshold_ms).to(eq(250))
    end

    it "defaults authenticate to allow all" do
      expect(config.authenticate.call(nil)).to(be(true))
    end

    it "has no featured tables by default" do
      expect(config.featured_tables).to(be_empty)
    end

    it "has no default columns by default" do
      expect(config.default_columns).to(be_empty)
    end
  end

  describe "#ai_enabled?" do
    it "returns false when nothing is configured" do
      expect(config.ai_enabled?).to(be(false))
    end

    it "returns true when ai_endpoint and ai_api_key are set" do
      config.ai_endpoint = "https://api.example.com/v1/chat"
      config.ai_api_key = "sk-test"
      expect(config.ai_enabled?).to(be(true))
    end

    it "returns true when ai_client is set" do
      config.ai_client = ->(**) { {} }
      expect(config.ai_enabled?).to(be(true))
    end

    it "returns false when only ai_endpoint is set" do
      config.ai_endpoint = "https://api.example.com/v1/chat"
      expect(config.ai_enabled?).to(be(false))
    end
  end

  describe "MysqlGenius.configure" do
    it "yields the configuration" do
      MysqlGenius.configure do |c|
        c.max_row_limit = 500
        c.blocked_tables = ["users"]
      end

      expect(MysqlGenius.configuration.max_row_limit).to(eq(500))
      expect(MysqlGenius.configuration.blocked_tables).to(eq(["users"]))
    end
  end

  describe '#database' do
    it 'creates a DatabaseConfig and yields it' do
      config.database(:analytics) do |db|
        db.blocked_tables = ['raw_events']
      end

      expect(config.databases[:analytics]).to(be_a(MysqlGenius::DatabaseConfig))
      expect(config.databases[:analytics].blocked_tables).to(eq(['raw_events']))
    end

    it 'reuses existing DatabaseConfig on repeated calls' do
      config.database(:analytics) do |db|
        db.blocked_tables = ['raw_events']
      end
      config.database(:analytics) do |db|
        db.max_row_limit = 500
      end

      expect(config.databases[:analytics].blocked_tables).to(eq(['raw_events']))
      expect(config.databases[:analytics].max_row_limit).to(eq(500))
    end

    it 'falls back to global config for unset values' do
      config.max_row_limit = 2000
      config.database(:analytics) {}

      expect(config.databases[:analytics].max_row_limit).to(eq(2000))
    end
  end

  describe '#databases' do
    it 'defaults to an empty hash' do
      expect(config.databases).to(eq({}))
    end
  end
end
