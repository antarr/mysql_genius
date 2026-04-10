# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/connection_pool"

RSpec.describe(MysqlGenius::ConnectionPool) do
  before do
    described_class.instance_variable_set(:@pools, {})
  end

  describe ".connection_for" do
    context "when no config is found for the spec name" do
      it "falls back to ActiveRecord::Base.connection" do
        base_connection = double("base_connection")
        base_pool = double("base_pool", connection: base_connection)
        allow(ActiveRecord::Base).to(receive_messages(configurations: {}, connection_pool: base_pool, connection: base_connection))

        result = described_class.connection_for("nonexistent")

        expect(result).to(eq(base_connection))
      end
    end

    context "when resolve_config raises an error" do
      it "falls back to ActiveRecord::Base.connection" do
        base_connection = double("base_connection")
        allow(ActiveRecord::Base).to(receive(:configurations).and_raise(StandardError, "boom"))
        allow(ActiveRecord::Base).to(receive(:connection).and_return(base_connection))

        result = described_class.connection_for("broken")

        expect(result).to(eq(base_connection))
      end
    end
  end

  describe ".resolve_config_legacy" do
    # Stub Rails.env for these tests only, without polluting other specs
    let(:rails_stub) { double("Rails", env: "development") }

    before do
      stub_const("Rails", rails_stub)
    end

    it "finds a top-level database key" do
      configs = {
        "development" => { "adapter" => "mysql2", "database" => "app_dev" },
        "analytics" => { "adapter" => "mysql2", "database" => "analytics_dev" },
      }

      result = described_class.send(:resolve_config_legacy, "analytics", configs)

      expect(result).to(eq({ "adapter" => "mysql2", "database" => "analytics_dev" }))
    end

    it "finds a nested database key under the environment" do
      configs = {
        "development" => {
          "primary" => { "adapter" => "mysql2", "database" => "app_dev" },
          "analytics" => { "adapter" => "mysql2", "database" => "analytics_dev" },
        },
      }

      result = described_class.send(:resolve_config_legacy, "analytics", configs)

      expect(result).to(eq({ "adapter" => "mysql2", "database" => "analytics_dev" }))
    end

    it "returns nil when the spec name is not found" do
      configs = {
        "development" => { "adapter" => "mysql2", "database" => "app_dev" },
      }

      result = described_class.send(:resolve_config_legacy, "nonexistent", configs)

      expect(result).to(be_nil)
    end

    it "prefers the environment-nested key over a top-level key" do
      configs = {
        "development" => {
          "analytics" => { "adapter" => "mysql2", "database" => "nested_analytics" },
        },
        "analytics" => { "adapter" => "mysql2", "database" => "top_level_analytics" },
      }

      result = described_class.send(:resolve_config_legacy, "analytics", configs)

      expect(result).to(eq({ "adapter" => "mysql2", "database" => "nested_analytics" }))
    end
  end
end
