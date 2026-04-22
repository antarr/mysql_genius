# frozen_string_literal: true

require "rails_helper"

RSpec.describe("Query execution routes", type: :request) do
  before do
    stub_connection(tables: ["users"], select_value: "8.0.30")
    allow(ActiveRecord::Base.connection).to(receive(:exec_query).and_return(
      fake_result(
        columns: ["id", "email"],
        rows: [[1, "alice@example.com"], [2, "bob@example.com"]],
      ),
    ))
  end

  describe "POST /mysql_genius/primary/execute" do
    it "returns JSON results for a valid SELECT" do
      post "/mysql_genius/primary/execute", sql: "SELECT id, email FROM users LIMIT 10"
      expect(last_response).to(be_ok)
      json = JSON.parse(last_response.body)
      expect(json).to(have_key("columns"))
      expect(json).to(have_key("rows"))
      expect(json).to(have_key("row_count"))
      expect(json).to(have_key("execution_time_ms"))
    end

    it "rejects non-SELECT statements with 422" do
      post "/mysql_genius/primary/execute", sql: "DELETE FROM users"
      expect(last_response.status).to(eq(422))
      json = JSON.parse(last_response.body)
      expect(json["error"]).to(be_present)
    end

    it "rejects queries against blocked tables with 422" do
      MysqlGenius.configure { |c| c.blocked_tables = ["users"] }
      post "/mysql_genius/primary/execute", sql: "SELECT * FROM users"
      expect(last_response.status).to(eq(422))
    end

    it "does not raise NoMethodError (boot-order regression guard)" do
      # The 0.4.0 bug: Core::Connection::ActiveRecordAdapter was not required
      # by lib/mysql_genius.rb, so the concern's "ActiveRecordAdapter.new(...)"
      # call raised "uninitialized constant" at runtime. Every tab was broken.
      # The `not_to raise_error` is redundant (Rails catches and returns 500)
      # but the `eq(200)` is the real regression guard.
      expect { post("/mysql_genius/primary/execute", sql: "SELECT 1") }.not_to(raise_error)
      expect(last_response.status).to(eq(200))
    end
  end

  describe "POST /mysql_genius/primary/explain" do
    before do
      allow(ActiveRecord::Base.connection).to(receive(:exec_query).with(/^EXPLAIN /)) do
        fake_result(
          columns: ["id", "select_type", "table", "type"],
          rows: [[1, "SIMPLE", "users", "ALL"]],
        )
      end
    end

    it "returns EXPLAIN rows for a valid SELECT" do
      post "/mysql_genius/primary/explain", sql: "SELECT id FROM users"
      expect(last_response).to(be_ok)
      json = JSON.parse(last_response.body)
      expect(json).to(have_key("columns"))
      expect(json).to(have_key("rows"))
    end

    it "rejects non-SELECT statements" do
      post "/mysql_genius/primary/explain", sql: "UPDATE users SET email = 'x'"
      expect(last_response.status).to(eq(422))
    end
  end
end
