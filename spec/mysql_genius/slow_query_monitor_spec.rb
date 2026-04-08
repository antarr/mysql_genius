require "spec_helper"
require "mysql_genius/slow_query_monitor"

RSpec.describe MysqlGenius::SlowQueryMonitor do
  describe ".redis_key" do
    it "returns the expected key" do
      expect(described_class.redis_key).to eq("mysql_genius:slow_queries")
    end
  end

  describe ".subscribe!" do
    let(:redis) { double("redis") }

    before do
      MysqlGenius.configure do |c|
        c.redis_url = "redis://localhost:6379/0"
        c.slow_query_threshold_ms = 250
      end

      allow(Redis).to receive(:new).and_return(redis)
      allow(redis).to receive(:lpush)
      allow(redis).to receive(:ltrim)

      # Clear any existing subscriptions
      ActiveSupport::Notifications.unsubscribe("sql.active_record") rescue nil
    end

    it "subscribes to sql.active_record notifications" do
      expect(ActiveSupport::Notifications).to receive(:subscribe).with("sql.active_record")
      described_class.subscribe!
    end

    context "when processing notifications" do
      before do
        described_class.subscribe!
      end

      after do
        ActiveSupport::Notifications.unsubscribe("sql.active_record")
      end

      it "captures slow SELECT queries" do
        expect(redis).to receive(:lpush).with("mysql_genius:slow_queries", anything)
        expect(redis).to receive(:ltrim).with("mysql_genius:slow_queries", 0, 199)

        start = Time.now
        finish = start + 0.5 # 500ms, above 250ms threshold

        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM users", name: "User Load") do
          # Simulate slow query by using publish directly
        end

        # Trigger the subscriber directly since instrument timing won't work
        ActiveSupport::Notifications.publish(
          "sql.active_record",
          start,
          finish,
          "test-id",
          { sql: "SELECT * FROM users", name: "User Load" }
        )
      end

      it "ignores queries below the threshold" do
        expect(redis).not_to receive(:lpush)

        start = Time.now
        finish = start + 0.01 # 10ms, below threshold

        ActiveSupport::Notifications.publish(
          "sql.active_record",
          start,
          finish,
          "test-id",
          { sql: "SELECT * FROM users", name: "User Load" }
        )
      end

      it "ignores non-SELECT queries" do
        expect(redis).not_to receive(:lpush)

        start = Time.now
        finish = start + 1.0

        ActiveSupport::Notifications.publish(
          "sql.active_record",
          start,
          finish,
          "test-id",
          { sql: "INSERT INTO users VALUES (1)", name: "SQL" }
        )
      end

      it "ignores EXPLAIN queries" do
        expect(redis).not_to receive(:lpush)

        start = Time.now
        finish = start + 1.0

        ActiveSupport::Notifications.publish(
          "sql.active_record",
          start,
          finish,
          "test-id",
          { sql: "SELECT * FROM users EXPLAIN something", name: "SQL" }
        )
      end

      it "ignores SCHEMA queries" do
        expect(redis).not_to receive(:lpush)

        start = Time.now
        finish = start + 1.0

        ActiveSupport::Notifications.publish(
          "sql.active_record",
          start,
          finish,
          "test-id",
          { sql: "SELECT * FROM SCHEMA tables", name: "SCHEMA" }
        )
      end

      it "gracefully handles Redis errors" do
        allow(redis).to receive(:lpush).and_raise(Redis::ConnectionError.new("Connection refused")) if defined?(Redis::ConnectionError)
        allow(redis).to receive(:lpush).and_raise(StandardError.new("Connection refused"))

        start = Time.now
        finish = start + 1.0

        expect {
          ActiveSupport::Notifications.publish(
            "sql.active_record",
            start,
            finish,
            "test-id",
            { sql: "SELECT * FROM users", name: "SQL" }
          )
        }.not_to raise_error
      end
    end
  end
end
