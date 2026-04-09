# frozen_string_literal: true

require "spec_helper"
require "active_support/notifications"
require "mysql_genius/slow_query_monitor"

# Stub Redis if not available
unless defined?(Redis)
  class Redis
    class ConnectionError < StandardError; end
    def initialize(**opts); end
    def lpush(key, value); end
    def ltrim(key, start, stop); end
  end
end

RSpec.describe(MysqlGenius::SlowQueryMonitor) do
  describe ".redis_key" do
    it "returns the expected key" do
      expect(described_class.redis_key).to(eq("mysql_genius:slow_queries"))
    end
  end

  describe ".subscribe!" do
    let(:redis) { double("redis") }

    before do
      MysqlGenius.configure do |c|
        c.redis_url = "redis://localhost:6379/0"
        c.slow_query_threshold_ms = 250
      end

      allow(Redis).to(receive(:new).and_return(redis))
      allow(redis).to(receive(:lpush))
      allow(redis).to(receive(:ltrim))

      # Clear any existing subscriptions
      begin
        ActiveSupport::Notifications.unsubscribe("sql.active_record")
      rescue
        nil
      end
    end

    it "subscribes to sql.active_record notifications" do
      expect(ActiveSupport::Notifications).to(receive(:subscribe).with("sql.active_record"))
      described_class.subscribe!
    end

    context "when processing notifications" do
      # We invoke the subscriber callback directly since ActiveSupport::Notifications.publish
      # does not dispatch to block-based (Timed) subscribers.
      let(:callback) do
        described_class.subscribe!.instance_variable_get(:@delegate)
      end

      after do
        ActiveSupport::Notifications.unsubscribe("sql.active_record")
      end

      def fire_callback(callback, duration_sec:, sql:, name: "SQL")
        start = Time.now
        finish = start + duration_sec
        callback.call("sql.active_record", start, finish, "test-id", { sql: sql, name: name })
      end

      it "captures slow SELECT queries" do
        expect(redis).to(receive(:lpush).with("mysql_genius:slow_queries", anything))
        expect(redis).to(receive(:ltrim).with("mysql_genius:slow_queries", 0, 199))

        fire_callback(callback, duration_sec: 0.5, sql: "SELECT * FROM users", name: "User Load")
      end

      it "ignores queries below the threshold" do
        expect(redis).not_to(receive(:lpush))

        fire_callback(callback, duration_sec: 0.01, sql: "SELECT * FROM users", name: "User Load")
      end

      it "ignores non-SELECT queries" do
        expect(redis).not_to(receive(:lpush))

        fire_callback(callback, duration_sec: 1.0, sql: "INSERT INTO users VALUES (1)")
      end

      it "ignores EXPLAIN queries" do
        expect(redis).not_to(receive(:lpush))

        fire_callback(callback, duration_sec: 1.0, sql: "SELECT * FROM users EXPLAIN something")
      end

      it "ignores SCHEMA queries" do
        expect(redis).not_to(receive(:lpush))

        fire_callback(callback, duration_sec: 1.0, sql: "SELECT * FROM SCHEMA tables", name: "SCHEMA")
      end

      it "gracefully handles Redis errors" do
        allow(redis).to(receive(:lpush).and_raise(StandardError.new("Connection refused")))

        expect do
          fire_callback(callback, duration_sec: 1.0, sql: "SELECT * FROM users")
        end.not_to(raise_error)
      end
    end
  end
end
