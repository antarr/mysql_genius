# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/stats_histories"

RSpec.describe(MysqlGenius::StatsHistories) do
  let(:histories) { described_class.new }
  let(:history_a) { double("StatsHistory:a") }
  let(:history_b) { double("StatsHistory:b") }

  describe "keyed access" do
    it "stores and retrieves histories by symbol or string key (stringified)" do
      histories["primary"] = history_a
      expect(histories["primary"]).to(be(history_a))
      expect(histories[:primary]).to(be(history_a))
    end

    it "returns nil for unknown keys via []" do
      expect(histories["nope"]).to(be_nil)
    end

    it "raises KeyError for fetch with unknown key and no default block" do
      expect { histories.fetch("nope") }.to(raise_error(KeyError))
    end

    it "honors the default block in fetch" do
      expect(histories.fetch("nope") { |k| "fallback:#{k}" }).to(eq("fallback:nope"))
    end
  end

  describe "collection methods" do
    before do
      histories["primary"] = history_a
      histories["analytics"] = history_b
    end

    it "#keys returns all database keys" do
      expect(histories.keys).to(contain_exactly("primary", "analytics"))
    end

    it "#values returns all histories" do
      expect(histories.values).to(contain_exactly(history_a, history_b))
    end

    it "#size returns the count" do
      expect(histories.size).to(eq(2))
    end

    it "#empty? reports false when populated, true otherwise" do
      expect(histories.empty?).to(be(false))
      expect(described_class.new.empty?).to(be(true))
    end

    it "#each_pair yields key, history pairs" do
      pairs = []
      histories.each_pair { |k, v| pairs << [k, v] }
      expect(pairs).to(contain_exactly(["primary", history_a], ["analytics", history_b]))
    end

    it "#first returns the first inserted history (helper for single-DB callers)" do
      expect(histories.first).to(be(history_a))
    end
  end

  describe "thread safety" do
    it "tolerates concurrent writes without raising" do
      threads = 10.times.map do |i|
        Thread.new { 100.times { histories[i.to_s] = i } }
      end
      threads.each(&:join)
      expect(histories.size).to(eq(10))
    end
  end
end
