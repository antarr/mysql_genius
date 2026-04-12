# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/desktop/config/mysql_config"

RSpec.describe(MysqlGenius::Desktop::Config::MysqlConfig) do
  describe ".from_hash" do
    it "applies defaults for port, password, and tls_mode" do
      config = described_class.from_hash({
        "host" => "db.example.com",
        "username" => "readonly",
        "database" => "app_production",
      })
      expect(config.host).to(eq("db.example.com"))
      expect(config.port).to(eq(3306))
      expect(config.username).to(eq("readonly"))
      expect(config.password).to(eq(""))
      expect(config.database).to(eq("app_production"))
      expect(config.tls_mode).to(eq("preferred"))
    end

    it "honours overrides for every field" do
      config = described_class.from_hash({
        "host" => "db.example.com",
        "port" => 3307,
        "username" => "readonly",
        "password" => "s3cret",
        "database" => "app_production",
        "tls_mode" => "required",
      })
      expect(config.port).to(eq(3307))
      expect(config.password).to(eq("s3cret"))
      expect(config.tls_mode).to(eq("required"))
    end

    it "accepts symbol keys as well as string keys" do
      config = described_class.from_hash({
        host: "db",
        username: "u",
        database: "d",
      })
      expect(config.host).to(eq("db"))
    end

    it "raises InvalidConfigError when host is missing" do
      expect do
        described_class.from_hash({ "username" => "u", "database" => "d" })
      end.to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /mysql: required fields missing: host/))
    end

    it "raises InvalidConfigError when multiple required fields are missing" do
      expect do
        described_class.from_hash({})
      end.to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /mysql: required fields missing: host, username, database/))
    end
  end
end
