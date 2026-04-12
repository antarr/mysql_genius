# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"

RSpec.describe("Query detail routes", type: :request) do
  let(:digest) { "abc123def456" }
  let(:digest_text) { "SELECT * FROM `users` WHERE `id` = ?" }

  before do
    @fake_adapter.stub_query(
      /COUNT_STAR AS calls/,
      columns: ["DIGEST_TEXT", "calls", "total_time_ms", "avg_time_ms", "max_time_ms", "rows_examined", "rows_sent", "FIRST_SEEN", "LAST_SEEN"],
      rows: [[digest_text, 42, 1234.5, 29.4, 100.0, 1000, 42, "2024-01-01 00:00:00", "2024-01-02 00:00:00"]],
    )
    @fake_adapter.stub_query(
      /SELECT DIGEST_TEXT FROM performance_schema/,
      columns: ["DIGEST_TEXT"],
      rows: [[digest_text]],
    )
    MysqlGenius::Desktop::App.set(:stats_history, nil)
    MysqlGenius::Desktop::App.set(:stats_collector, nil)
  end

  after do
    MysqlGenius::Desktop::App.set(:stats_history, nil)
    MysqlGenius::Desktop::App.set(:stats_collector, nil)
  end

  describe "GET /queries/:digest" do
    it "returns 200" do
      get "/queries/#{digest}"
      expect(last_response.status).to(eq(200))
    end

    it "renders the query detail template" do
      get "/queries/#{digest}"
      expect(last_response.body).to(include("qd-content"))
      expect(last_response.body).to(include("Query Detail"))
    end
  end

  describe "GET /api/query_history/:digest" do
    context "when stats_history is nil (collection disabled)" do
      it "returns 200 with empty history array" do
        get "/api/query_history/#{digest}"
        expect(last_response.status).to(eq(200))
        json = JSON.parse(last_response.body)
        expect(json).to(have_key("query"))
        expect(json["history"]).to(eq([]))
      end
    end

    context "when stats_history is set" do
      let(:stats_history) { MysqlGenius::Core::Analysis::StatsHistory.new }

      before do
        stats_history.record(digest_text, {
          timestamp: "2024-01-02T10:00:00Z",
          calls: 5,
          total_time_ms: 150.0,
          avg_time_ms: 30.0,
        })
        MysqlGenius::Desktop::App.set(:stats_history, stats_history)
      end

      it "returns 200 with query and history keys" do
        get "/api/query_history/#{digest}"
        expect(last_response.status).to(eq(200))
        json = JSON.parse(last_response.body)
        expect(json).to(have_key("query"))
        expect(json).to(have_key("history"))
        expect(json["history"].length).to(eq(1))
      end
    end
  end
end
# rubocop:enable RSpec/InstanceVariable
