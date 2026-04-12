# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::StatsCollector) do
  subject(:collector) do
    described_class.new(connection_provider: connection_provider, history: history, interval: 60)
  end

  let(:history) { MysqlGenius::Core::Analysis::StatsHistory.new }
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:connection_provider) { -> { connection } }

  before do
    stub_perf_schema(
      ["SELECT ? FROM `users`", 100, 500.0],
      ["SELECT ? FROM `orders`", 200, 1000.0],
    )
  end

  after do
    collector.stop if collector.running?
  end

  def stub_perf_schema(*rows)
    connection.instance_variable_set(:@stubs, [])
    connection.stub_query(
      /performance_schema/,
      columns: ["DIGEST_TEXT", "COUNT_STAR", "total_time_ms"],
      rows: rows,
    )
  end

  describe "#start" do
    it "returns self" do
      expect(collector.start).to(equal(collector))
    end

    it "marks the collector as running" do
      collector.start
      expect(collector).to(be_running)
    end

    it "is idempotent when already running" do
      collector.start
      collector.start
      expect(collector).to(be_running)
    end
  end

  describe "#stop" do
    it "marks the collector as not running" do
      collector.start
      collector.stop
      expect(collector).not_to(be_running)
    end

    it "is safe to call when not started" do
      expect { collector.stop }.not_to(raise_error)
    end
  end

  describe "#running?" do
    it "is false before start" do
      expect(collector).not_to(be_running)
    end
  end

  describe "delta computation" do
    it "records nothing on the first tick (no previous data)" do
      collector.send(:tick)
      expect(history.digests).to(be_empty)
    end

    it "records delta snapshots on the second tick" do
      collector.send(:tick)

      stub_perf_schema(
        ["SELECT ? FROM `users`", 150, 750.0],
        ["SELECT ? FROM `orders`", 220, 1100.0],
      )
      collector.send(:tick)

      users = history.series_for("SELECT ? FROM `users`")
      expect(users.length).to(eq(1))
      expect(users.first[:calls]).to(eq(50))
      expect(users.first[:total_time_ms]).to(eq(250.0))
      expect(users.first[:avg_time_ms]).to(eq(5.0))

      orders = history.series_for("SELECT ? FROM `orders`")
      expect(orders.length).to(eq(1))
      expect(orders.first[:calls]).to(eq(20))
      expect(orders.first[:total_time_ms]).to(eq(100.0))
      expect(orders.first[:avg_time_ms]).to(eq(5.0))
    end

    it "includes an ISO 8601 timestamp in each snapshot" do
      collector.send(:tick)

      stub_perf_schema(["SELECT ? FROM `users`", 110, 550.0])
      collector.send(:tick)

      snapshot = history.series_for("SELECT ? FROM `users`").first
      expect(snapshot[:timestamp]).to(match(/\A\d{4}-\d{2}-\d{2}T/))
    end

    it "does not record a delta for digests not seen in the previous tick" do
      collector.send(:tick)

      stub_perf_schema(
        ["SELECT ? FROM `users`", 150, 750.0],
        ["SELECT ? FROM `products`", 50, 200.0],
      )
      collector.send(:tick)

      expect(history.series_for("SELECT ? FROM `users`").length).to(eq(1))
      expect(history.series_for("SELECT ? FROM `products`")).to(be_empty)
    end
  end

  describe "negative delta clamping" do
    it "records zero for negative deltas (server restart)" do
      collector.send(:tick)

      stub_perf_schema(["SELECT ? FROM `users`", 10, 50.0])
      collector.send(:tick)

      series = history.series_for("SELECT ? FROM `users`")
      expect(series.length).to(eq(1))
      expect(series.first[:calls]).to(eq(0))
      expect(series.first[:total_time_ms]).to(eq(0))
      expect(series.first[:avg_time_ms]).to(eq(0.0))
    end
  end

  describe "error handling" do
    it "stops gracefully when performance_schema is unavailable" do
      error_connection = MysqlGenius::Core::Connection::FakeAdapter.new
      error_connection.stub_query(
        /performance_schema/,
        raises: StandardError.new("performance_schema not available"),
      )

      error_collector = described_class.new(
        connection_provider: -> { error_connection },
        history: history,
        interval: 60,
      )

      error_collector.start
      sleep(0.15)
      expect(error_collector).not_to(be_running)
    end
  end
end
