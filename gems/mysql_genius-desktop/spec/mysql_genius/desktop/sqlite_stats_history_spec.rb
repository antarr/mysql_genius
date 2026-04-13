# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "mysql_genius/desktop/database"
require "mysql_genius/desktop/sqlite_stats_history"

RSpec.describe(MysqlGenius::Desktop::SqliteStatsHistory) do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db_path) { File.join(tmpdir, "test.db") }
  let(:database) { MysqlGenius::Desktop::Database.new(db_path) }
  let(:history) { described_class.new(database) }

  after { FileUtils.remove_entry(tmpdir) }

  describe "#record" do
    it "stores a snapshot with symbol keys" do
      history.record("SELECT 1", {
        timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        calls: 5,
        total_time_ms: 123.4,
        avg_time_ms: 24.68,
      })
      series = history.series_for("SELECT 1")
      expect(series.length).to(eq(1))
      expect(series.first[:calls]).to(eq(5))
      expect(series.first[:total_time_ms]).to(eq(123.4))
      expect(series.first[:avg_time_ms]).to(eq(24.68))
    end

    it "stores a snapshot with string keys" do
      history.record("SELECT 1", {
        "timestamp" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "calls" => 3,
        "total_time_ms" => 50.0,
        "avg_time_ms" => 16.7,
      })
      series = history.series_for("SELECT 1")
      expect(series.length).to(eq(1))
      expect(series.first[:calls]).to(eq(3))
    end

    it "defaults missing fields to zero" do
      history.record("SELECT 1", { timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ") })
      series = history.series_for("SELECT 1")
      expect(series.first[:calls]).to(eq(0))
      expect(series.first[:total_time_ms]).to(eq(0.0))
      expect(series.first[:avg_time_ms]).to(eq(0.0))
    end
  end

  describe "#series_for" do
    it "returns snapshots ordered by timestamp with symbol keys" do
      now = Time.now.utc
      history.record("SELECT 1", { timestamp: (now - 60).strftime("%Y-%m-%dT%H:%M:%SZ"), calls: 1, total_time_ms: 10.0, avg_time_ms: 10.0 })
      history.record("SELECT 1", { timestamp: now.strftime("%Y-%m-%dT%H:%M:%SZ"), calls: 2, total_time_ms: 20.0, avg_time_ms: 10.0 })

      series = history.series_for("SELECT 1")
      expect(series.length).to(eq(2))
      expect(series.first[:calls]).to(eq(1))
      expect(series.last[:calls]).to(eq(2))
      expect(series.first[:timestamp] <= series.last[:timestamp]).to(be(true))
    end

    it "returns an empty array for unknown digest" do
      expect(history.series_for("SELECT unknown")).to(eq([]))
    end
  end

  describe "#digests" do
    it "returns distinct digest texts" do
      now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      history.record("SELECT 1", { timestamp: now, calls: 1, total_time_ms: 1.0, avg_time_ms: 1.0 })
      history.record("SELECT 2", { timestamp: now, calls: 1, total_time_ms: 1.0, avg_time_ms: 1.0 })
      history.record("SELECT 1", { timestamp: now, calls: 2, total_time_ms: 2.0, avg_time_ms: 1.0 })

      expect(history.digests).to(contain_exactly("SELECT 1", "SELECT 2"))
    end
  end

  describe "#clear" do
    it "removes all snapshots" do
      now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      history.record("SELECT 1", { timestamp: now, calls: 1, total_time_ms: 1.0, avg_time_ms: 1.0 })
      history.clear
      expect(history.digests).to(be_empty)
    end
  end

  describe "API compatibility with StatsHistory" do
    it "responds to the same public methods as Core::Analysis::StatsHistory" do
      expect(history).to(respond_to(:record, :series_for, :digests, :clear))
    end
  end
end
