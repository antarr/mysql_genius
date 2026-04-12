# frozen_string_literal: true

require "rack_helper"

RSpec.describe("Analysis routes", type: :request) do
  describe "GET /duplicate_indexes" do
    it "delegates to Core::Analysis::DuplicateIndexes and returns JSON" do
      instance = instance_double(MysqlGenius::Core::Analysis::DuplicateIndexes, call: [])
      allow(MysqlGenius::Core::Analysis::DuplicateIndexes).to(receive(:new).and_return(instance))
      get "/duplicate_indexes"
      expect(last_response.status).to(eq(200))
      expect(JSON.parse(last_response.body)).to(eq([]))
    end
  end

  describe "GET /table_sizes" do
    it "delegates to Core::Analysis::TableSizes and returns JSON" do
      instance = instance_double(MysqlGenius::Core::Analysis::TableSizes, call: [{ "table_name" => "users", "rows" => 100 }])
      allow(MysqlGenius::Core::Analysis::TableSizes).to(receive(:new).and_return(instance))
      get "/table_sizes"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body.first["table_name"]).to(eq("users"))
    end
  end

  describe "GET /query_stats" do
    it "delegates to Core::Analysis::QueryStats with sort and limit params" do
      instance = instance_double(MysqlGenius::Core::Analysis::QueryStats)
      allow(MysqlGenius::Core::Analysis::QueryStats).to(receive(:new).and_return(instance))
      allow(instance).to(receive(:call).with(sort: "total_time", limit: 20).and_return([]))
      get "/query_stats?sort=total_time&limit=20"
      expect(last_response.status).to(eq(200))
    end

    it "returns 422 when performance_schema is unavailable" do
      instance = instance_double(MysqlGenius::Core::Analysis::QueryStats)
      allow(MysqlGenius::Core::Analysis::QueryStats).to(receive(:new).and_return(instance))
      allow(instance).to(receive(:call).and_raise(StandardError, "Table 'performance_schema.events_statements_summary_by_digest' doesn't exist"))
      get "/query_stats"
      expect(last_response.status).to(eq(422))
      body = JSON.parse(last_response.body)
      expect(body["error"]).to(include("performance_schema"))
    end
  end

  describe "GET /unused_indexes" do
    it "delegates to Core::Analysis::UnusedIndexes" do
      instance = instance_double(MysqlGenius::Core::Analysis::UnusedIndexes, call: [])
      allow(MysqlGenius::Core::Analysis::UnusedIndexes).to(receive(:new).and_return(instance))
      get "/unused_indexes"
      expect(last_response.status).to(eq(200))
    end
  end

  describe "GET /server_overview" do
    it "delegates to Core::Analysis::ServerOverview" do
      instance = instance_double(MysqlGenius::Core::Analysis::ServerOverview, call: { "version" => "8.0.35" })
      allow(MysqlGenius::Core::Analysis::ServerOverview).to(receive(:new).and_return(instance))
      get "/server_overview"
      expect(last_response.status).to(eq(200))
      expect(JSON.parse(last_response.body)).to(eq({ "version" => "8.0.35" }))
    end

    it "returns 422 with a helpful message on failure" do
      instance = instance_double(MysqlGenius::Core::Analysis::ServerOverview)
      allow(MysqlGenius::Core::Analysis::ServerOverview).to(receive(:new).and_return(instance))
      allow(instance).to(receive(:call).and_raise(StandardError, "access denied"))
      get "/server_overview"
      expect(last_response.status).to(eq(422))
      expect(JSON.parse(last_response.body)["error"]).to(include("Failed to load server overview"))
    end
  end
end
