# frozen_string_literal: true

require "rails_helper"

RSpec.describe("Query detail routes", type: :request) do
  let(:digest) { "abc123def456" }
  let(:digest_text) { "SELECT * FROM `users` WHERE `id` = ?" }

  let(:current_stats_result) do
    fake_result(
      columns: ["DIGEST_TEXT", "calls", "total_time_ms", "avg_time_ms", "max_time_ms", "rows_examined", "rows_sent", "FIRST_SEEN", "LAST_SEEN"],
      rows: [[digest_text, 42, 1234.5, 29.4, 100.0, 1000, 42, "2024-01-01 00:00:00", "2024-01-02 00:00:00"]],
    )
  end

  let(:digest_text_result) do
    fake_result(
      columns: ["DIGEST_TEXT"],
      rows: [[digest_text]],
    )
  end

  before do
    stub_connection(
      tables: ["users"],
      exec_query: {
        /COUNT_STAR AS calls/ => current_stats_result,
        /SELECT DIGEST_TEXT FROM performance_schema/ => digest_text_result,
      },
      allow_unmatched_exec_query: true,
    )
  end

  describe "GET /mysql_genius/primary/queries/:digest" do
    it "returns 200" do
      get "/mysql_genius/primary/queries/#{digest}"
      expect(last_response.status).to(eq(200))
    end

    it "renders the query detail template" do
      get "/mysql_genius/primary/queries/#{digest}"
      expect(last_response.body).to(include("qd-content"))
      expect(last_response.body).to(include("Query Detail"))
    end
  end

  describe "GET /mysql_genius/primary/api/query_history/:digest" do
    context "when stats_history is nil (collection disabled)" do
      before { MysqlGenius.stats_history = nil }
      after  { MysqlGenius.stats_history = nil }

      it "returns 200 with empty history array" do
        get "/mysql_genius/primary/api/query_history/#{digest}"
        expect(last_response.status).to(eq(200))
        json = JSON.parse(last_response.body)
        expect(json).to(have_key("query"))
        expect(json["history"]).to(eq([]))
      end
    end

    context "when stats_history is a legacy singleton StatsHistory (pre-rc2 back-compat)" do
      let(:stats_history) { MysqlGenius::Core::Analysis::StatsHistory.new }

      before do
        stats_history.record(digest_text, {
          timestamp: "2024-01-02T10:00:00Z",
          calls: 5,
          total_time_ms: 150.0,
          avg_time_ms: 30.0,
        })
        MysqlGenius.stats_history = stats_history
      end

      after { MysqlGenius.stats_history = nil }

      it "returns 200 with query and history keys" do
        get "/mysql_genius/primary/api/query_history/#{digest}"
        expect(last_response.status).to(eq(200))
        json = JSON.parse(last_response.body)
        expect(json).to(have_key("query"))
        expect(json).to(have_key("history"))
        expect(json["history"].length).to(eq(1))
      end
    end

    context "when stats_history is a StatsHistories collection (rc2+)" do
      let(:primary_history) { MysqlGenius::Core::Analysis::StatsHistory.new }
      let(:other_history) { MysqlGenius::Core::Analysis::StatsHistory.new }

      before do
        # Only the primary DB's history has data for this digest. If the
        # controller accidentally used the wrong key, the test would get 0
        # history rows and we'd know.
        primary_history.record(digest_text, { timestamp: "t1", calls: 5, avg_time_ms: 30.0 })
        other_history.record(digest_text, { timestamp: "t2", calls: 99, avg_time_ms: 999.0 })

        histories = MysqlGenius::StatsHistories.new
        histories["primary"]   = primary_history
        histories["analytics"] = other_history
        MysqlGenius.stats_history = histories
      end

      after { MysqlGenius.stats_history = nil }

      it "returns only the current database's history series" do
        get "/mysql_genius/primary/api/query_history/#{digest}"
        json = JSON.parse(last_response.body)
        expect(json["history"].length).to(eq(1))
        expect(json["history"].first["calls"]).to(eq(5)) # primary's, not analytics'
      end

      it "returns an empty history when the current database has no recorded snapshots" do
        # A database in the registry without data for this digest should yield [].
        empty_history = MysqlGenius::Core::Analysis::StatsHistory.new
        histories = MysqlGenius::StatsHistories.new
        histories["primary"] = empty_history
        MysqlGenius.stats_history = histories

        get "/mysql_genius/primary/api/query_history/#{digest}"
        json = JSON.parse(last_response.body)
        expect(json["history"]).to(eq([]))
      end
    end
  end
end
