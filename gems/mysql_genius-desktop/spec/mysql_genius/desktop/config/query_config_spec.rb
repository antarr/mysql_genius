# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/desktop/config/mysql_config"
require "mysql_genius/desktop/config/query_config"

RSpec.describe(MysqlGenius::Desktop::Config::QueryConfig) do
  describe ".from_hash" do
    it "applies defaults matching the Rails adapter's ergonomics" do
      config = described_class.from_hash({})
      expect(config.default_row_limit).to(eq(100))
      expect(config.max_row_limit).to(eq(10_000))
      expect(config.timeout_seconds).to(eq(10))
    end

    it "derives query_timeout_ms from timeout_seconds" do
      config = described_class.from_hash({ "timeout_seconds" => 30 })
      expect(config.timeout_seconds).to(eq(30))
      expect(config.query_timeout_ms).to(eq(30_000))
    end

    it "honours explicit row limits" do
      config = described_class.from_hash({ "default_row_limit" => 50, "max_row_limit" => 5_000 })
      expect(config.default_row_limit).to(eq(50))
      expect(config.max_row_limit).to(eq(5_000))
    end
  end
end
