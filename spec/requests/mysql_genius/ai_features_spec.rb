# frozen_string_literal: true

require "rails_helper"

RSpec.describe("AI feature routes", type: :request) do
  let(:ai_client) { instance_double(MysqlGenius::Core::Ai::Client) }

  before do
    stub_connection(tables: ["users"])
    empty_result = fake_result
    # root_cause action iterates exec_query results with .each — stub it here
    # since fake_result doesn't include .each by default.
    allow(empty_result).to(receive(:each).and_yield({}))
    allow(ActiveRecord::Base.connection).to(receive_messages(exec_query: empty_result, select_value: "8.0.35"))
    allow(ActiveRecord::Base.connection).to(receive(:columns).with(anything).and_return([]))
    allow(ActiveRecord::Base.connection).to(receive(:indexes).with(anything).and_return([]))
    allow(ActiveRecord::Base.connection).to(receive(:primary_key).with(anything).and_return("id"))

    MysqlGenius.configure do |c|
      c.ai_endpoint = "http://localhost/ai"
      c.ai_api_key = "test-key"
      c.ai_model = "test-model"
    end

    allow(MysqlGenius::Core::Ai::Client).to(receive(:new).and_return(ai_client))
    allow(ai_client).to(receive(:chat).and_return({ "explanation" => "canned response" }))
  end

  describe "POST /mysql_genius/primary/suggest" do
    it "returns 200 when AI is configured" do
      allow(ai_client).to(receive(:chat).and_return({ "sql" => "SELECT 1", "explanation" => "ok" }))
      post "/mysql_genius/primary/suggest", prompt: "all users"
      expect(last_response).to(be_ok)
    end

    it "returns 404 when AI is not configured" do
      MysqlGenius.configure { |c| c.ai_endpoint = nil }
      post "/mysql_genius/primary/suggest", prompt: "all users"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /mysql_genius/primary/optimize" do
    it "returns 200 with SQL + explain rows" do
      post "/mysql_genius/primary/optimize", sql: "SELECT 1", explain_rows: [[{ "id" => 1 }]]
      expect(last_response).to(be_ok)
    end
  end

  describe "POST /mysql_genius/primary/describe_query" do
    it "returns 200 for a non-blank SQL" do
      post "/mysql_genius/primary/describe_query", sql: "SELECT 1"
      expect(last_response).to(be_ok)
    end

    it "returns 422 for blank SQL" do
      post "/mysql_genius/primary/describe_query", sql: ""
      expect(last_response.status).to(eq(422))
    end
  end

  describe "POST /mysql_genius/primary/schema_review" do
    it "returns 200 with or without a table param" do
      post "/mysql_genius/primary/schema_review"
      expect(last_response).to(be_ok)
    end
  end

  describe "POST /mysql_genius/primary/rewrite_query" do
    it "returns 200 for a valid SQL" do
      post "/mysql_genius/primary/rewrite_query", sql: "SELECT 1"
      expect(last_response).to(be_ok)
    end
  end

  describe "POST /mysql_genius/primary/index_advisor" do
    it "returns 200 with SQL + explain rows" do
      post "/mysql_genius/primary/index_advisor", sql: "SELECT 1 FROM users", explain_rows: [[{ "id" => 1 }]]
      expect(last_response).to(be_ok)
    end

    it "returns 422 when explain_rows are missing" do
      post "/mysql_genius/primary/index_advisor", sql: "SELECT 1"
      expect(last_response.status).to(eq(422))
    end
  end

  describe "POST /mysql_genius/primary/anomaly_detection" do
    it "returns 200 (stays Rails-side in Phase 2a)" do
      post "/mysql_genius/primary/anomaly_detection"
      expect(last_response).to(be_ok)
    end
  end

  describe "POST /mysql_genius/primary/root_cause" do
    it "returns 200 (stays Rails-side in Phase 2a)" do
      post "/mysql_genius/primary/root_cause"
      expect(last_response).to(be_ok)
    end
  end

  describe "POST /mysql_genius/primary/migration_risk" do
    it "returns 200 with a migration body" do
      post "/mysql_genius/primary/migration_risk", migration: "ALTER TABLE users ADD INDEX"
      expect(last_response).to(be_ok)
    end

    it "returns 422 when migration body is blank" do
      post "/mysql_genius/primary/migration_risk", migration: ""
      expect(last_response.status).to(eq(422))
    end
  end

  describe "POST /mysql_genius/primary/variable_review" do
    it "returns 200 when AI is configured" do
      post "/mysql_genius/primary/variable_review"
      expect(last_response).to(be_ok)
    end

    it "returns 404 when AI is not configured" do
      MysqlGenius.configure { |c| c.ai_endpoint = nil }
      post "/mysql_genius/primary/variable_review"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /mysql_genius/primary/connection_advisor" do
    it "returns 200 when AI is configured" do
      post "/mysql_genius/primary/connection_advisor"
      expect(last_response).to(be_ok)
    end

    it "returns 404 when AI is not configured" do
      MysqlGenius.configure { |c| c.ai_endpoint = nil }
      post "/mysql_genius/primary/connection_advisor"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /mysql_genius/primary/workload_digest" do
    it "returns 200 when AI is configured" do
      post "/mysql_genius/primary/workload_digest"
      expect(last_response).to(be_ok)
    end

    it "returns 404 when AI is not configured" do
      MysqlGenius.configure { |c| c.ai_endpoint = nil }
      post "/mysql_genius/primary/workload_digest"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /mysql_genius/primary/innodb_health" do
    it "returns 200 when AI is configured" do
      post "/mysql_genius/primary/innodb_health"
      expect(last_response).to(be_ok)
    end

    it "returns 404 when AI is not configured" do
      MysqlGenius.configure { |c| c.ai_endpoint = nil }
      post "/mysql_genius/primary/innodb_health"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /mysql_genius/primary/index_planner" do
    it "returns 200 when AI is configured" do
      post "/mysql_genius/primary/index_planner"
      expect(last_response).to(be_ok)
    end

    it "returns 404 when AI is not configured" do
      MysqlGenius.configure { |c| c.ai_endpoint = nil }
      post "/mysql_genius/primary/index_planner"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "POST /mysql_genius/primary/pattern_grouper" do
    it "returns 200 when AI is configured" do
      post "/mysql_genius/primary/pattern_grouper"
      expect(last_response).to(be_ok)
    end

    it "returns 404 when AI is not configured" do
      MysqlGenius.configure { |c| c.ai_endpoint = nil }
      post "/mysql_genius/primary/pattern_grouper"
      expect(last_response.status).to(eq(404))
    end
  end
end
