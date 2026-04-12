# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/desktop/config/mysql_config"
require "mysql_genius/desktop/config/ai_config"

RSpec.describe(MysqlGenius::Desktop::Config::AiConfig) do
  describe ".from_hash" do
    it "disables AI by default when the section is empty" do
      config = described_class.from_hash({})
      expect(config.enabled?).to(be(false))
    end

    it "disables AI when enabled: false is set explicitly" do
      config = described_class.from_hash({
        "enabled" => false,
        "endpoint" => "https://api.example.com/v1/chat/completions",
        "api_key" => "key",
      })
      expect(config.enabled?).to(be(false))
    end

    it "enables AI when endpoint + api_key are present and enabled is not false" do
      config = described_class.from_hash({
        "endpoint" => "https://api.example.com/v1/chat/completions",
        "api_key" => "key",
      })
      expect(config.enabled?).to(be(true))
    end

    it "applies defaults for auth_style, model, system_context, and domain_context" do
      config = described_class.from_hash({
        "endpoint" => "https://api.example.com/v1/chat/completions",
        "api_key" => "key",
      })
      expect(config.auth_style).to(eq(:bearer))
      expect(config.model).to(eq(""))
      expect(config.system_context).to(eq(""))
      expect(config.domain_context).to(eq(""))
    end

    it "honours explicit auth_style, model, system_context, and domain_context" do
      config = described_class.from_hash({
        "endpoint" => "https://api.example.com/v1/chat/completions",
        "api_key" => "key",
        "auth_style" => "api_key",
        "model" => "gpt-4o-mini",
        "system_context" => "This is an analytics warehouse.",
        "domain_context" => "Prefer window functions over correlated subqueries.",
      })
      expect(config.auth_style).to(eq(:api_key))
      expect(config.model).to(eq("gpt-4o-mini"))
      expect(config.system_context).to(eq("This is an analytics warehouse."))
      expect(config.domain_context).to(eq("Prefer window functions over correlated subqueries."))
    end
  end
end
