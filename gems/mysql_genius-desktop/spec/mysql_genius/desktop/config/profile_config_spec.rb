# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/desktop/config/mysql_config"
require "mysql_genius/desktop/config/profile_config"

RSpec.describe(MysqlGenius::Desktop::Config::ProfileConfig) do
  describe ".from_hash" do
    it "builds a ProfileConfig with a name and MysqlConfig" do
      profile = described_class.from_hash({
        "name" => "production",
        "mysql" => { "host" => "db.prod.com", "username" => "readonly", "database" => "app_production" },
      })
      expect(profile.name).to(eq("production"))
      expect(profile.mysql).to(be_a(MysqlGenius::Desktop::Config::MysqlConfig))
      expect(profile.mysql.host).to(eq("db.prod.com"))
    end

    it "raises InvalidConfigError when name is missing" do
      expect do
        described_class.from_hash({ "mysql" => { "host" => "h", "username" => "u", "database" => "d" } })
      end.to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /profile: name is required/))
    end

    it "raises InvalidConfigError when mysql section is missing" do
      expect do
        described_class.from_hash({ "name" => "test" })
      end.to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /profile 'test': mysql section is required/))
    end

    it "delegates MysqlConfig required-field validation" do
      expect do
        described_class.from_hash({ "name" => "test", "mysql" => { "host" => "h" } })
      end.to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /mysql: required fields missing/))
    end
  end
end
