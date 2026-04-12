# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/desktop/config/mysql_config"
require "mysql_genius/desktop/config/server_config"

RSpec.describe(MysqlGenius::Desktop::Config::ServerConfig) do
  describe ".from_hash" do
    it "applies defaults for port and bind" do
      config = described_class.from_hash({})
      expect(config.port).to(eq(4567))
      expect(config.bind).to(eq("127.0.0.1"))
    end

    it "honours explicit port and bind values" do
      config = described_class.from_hash({ "port" => 8080, "bind" => "0.0.0.0" })
      expect(config.port).to(eq(8080))
      expect(config.bind).to(eq("0.0.0.0"))
    end

    it "applies override_port when provided (CLI --port wins over YAML)" do
      config = described_class.from_hash({ "port" => 8080 }, override_port: 9000)
      expect(config.port).to(eq(9000))
    end

    it "applies override_bind when provided (CLI --bind wins over YAML)" do
      config = described_class.from_hash({ "bind" => "0.0.0.0" }, override_bind: "127.0.0.1")
      expect(config.bind).to(eq("127.0.0.1"))
    end

    it "treats nil overrides as absent" do
      config = described_class.from_hash({ "port" => 8080 }, override_port: nil, override_bind: nil)
      expect(config.port).to(eq(8080))
    end
  end
end
