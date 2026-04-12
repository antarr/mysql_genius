# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::StatsHistory) do
  subject(:history) { described_class.new(max_samples: 3) }

  let(:snapshot_a) { { timestamp: "2026-04-10T00:00:00Z", calls: 10, total_time_ms: 100.0, avg_time_ms: 10.0 } }
  let(:snapshot_b) { { timestamp: "2026-04-10T01:00:00Z", calls: 20, total_time_ms: 200.0, avg_time_ms: 10.0 } }
  let(:snapshot_c) { { timestamp: "2026-04-10T02:00:00Z", calls: 30, total_time_ms: 300.0, avg_time_ms: 10.0 } }
  let(:snapshot_d) { { timestamp: "2026-04-10T03:00:00Z", calls: 40, total_time_ms: 400.0, avg_time_ms: 10.0 } }

  describe "#record and #series_for" do
    it "returns an empty array for unknown digests" do
      expect(history.series_for("unknown")).to(eq([]))
    end

    it "appends snapshots in insertion order (oldest to newest)" do
      history.record("SELECT 1", snapshot_a)
      history.record("SELECT 1", snapshot_b)

      series = history.series_for("SELECT 1")
      expect(series).to(eq([snapshot_a, snapshot_b]))
    end

    it "drops the oldest entry when max_samples is reached" do
      history.record("SELECT 1", snapshot_a)
      history.record("SELECT 1", snapshot_b)
      history.record("SELECT 1", snapshot_c)
      history.record("SELECT 1", snapshot_d)

      series = history.series_for("SELECT 1")
      expect(series.length).to(eq(3))
      expect(series.first).to(eq(snapshot_b))
      expect(series.last).to(eq(snapshot_d))
    end

    it "returns a copy so callers cannot mutate internal state" do
      history.record("SELECT 1", snapshot_a)

      series = history.series_for("SELECT 1")
      series.clear

      expect(history.series_for("SELECT 1")).to(eq([snapshot_a]))
    end
  end

  describe "#digests" do
    it "returns all known digest keys" do
      history.record("SELECT 1", snapshot_a)
      history.record("SELECT 2", snapshot_b)

      expect(history.digests).to(contain_exactly("SELECT 1", "SELECT 2"))
    end

    it "returns an empty array when no data has been recorded" do
      expect(history.digests).to(eq([]))
    end
  end

  describe "#clear" do
    it "empties all data" do
      history.record("SELECT 1", snapshot_a)
      history.record("SELECT 2", snapshot_b)

      history.clear

      expect(history.digests).to(eq([]))
      expect(history.series_for("SELECT 1")).to(eq([]))
    end
  end

  describe "default max_samples" do
    it "defaults to 1440" do
      default_history = described_class.new
      1441.times { |i| default_history.record("q", { timestamp: i }) }

      expect(default_history.series_for("q").length).to(eq(1440))
    end
  end

  describe "thread safety" do
    it "handles concurrent writes without errors" do
      large_history = described_class.new(max_samples: 10_000)

      threads = 4.times.map do |t|
        Thread.new do
          500.times { |i| large_history.record("q#{t}", { timestamp: i }) }
        end
      end
      threads.each(&:join)

      expect(large_history.digests.length).to(eq(4))
      4.times do |t|
        expect(large_history.series_for("q#{t}").length).to(eq(500))
      end
    end
  end
end
