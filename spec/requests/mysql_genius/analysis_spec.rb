# frozen_string_literal: true

require "rails_helper"

RSpec.describe("Analysis routes", type: :request) do
  before do
    # Return canned information_schema and performance_schema results for
    # all the SELECTs the analysis classes emit. The actual analysis logic
    # is unit-tested in gems/mysql_genius-core/spec/.../analysis/*_spec.rb;
    # these request specs only verify routing/dispatch/JSON serialization.
    stub_connection(tables: ["users"])
    allow(ActiveRecord::Base.connection).to(receive_messages(exec_query: fake_result, select_value: "8.0.35"))
  end

  it "GET /mysql_genius/duplicate_indexes returns 200 + JSON array" do
    get "/mysql_genius/duplicate_indexes"
    expect(last_response).to(be_ok)
    expect(JSON.parse(last_response.body)).to(be_an(Array))
  end

  it "GET /mysql_genius/table_sizes returns 200 + JSON array" do
    get "/mysql_genius/table_sizes"
    expect(last_response).to(be_ok)
    expect(JSON.parse(last_response.body)).to(be_an(Array))
  end

  it "GET /mysql_genius/query_stats returns 200 + JSON array" do
    get "/mysql_genius/query_stats"
    expect(last_response).to(be_ok)
    expect(JSON.parse(last_response.body)).to(be_an(Array))
  end

  it "GET /mysql_genius/unused_indexes returns 200 + JSON array" do
    get "/mysql_genius/unused_indexes"
    expect(last_response).to(be_ok)
    expect(JSON.parse(last_response.body)).to(be_an(Array))
  end

  it "GET /mysql_genius/server_overview returns 200 + JSON object" do
    get "/mysql_genius/server_overview"
    expect(last_response).to(be_ok)
    json = JSON.parse(last_response.body)
    expect(json).to(be_a(Hash))
    expect(json).to(have_key("server"))
  end

  it "GET /mysql_genius/slow_queries returns 200 + empty array when Redis not configured" do
    # Redis is not configured in the test env; should return [] not raise.
    get "/mysql_genius/slow_queries"
    expect(last_response).to(be_ok)
    expect(JSON.parse(last_response.body)).to(eq([]))
  end

  it "does not raise NoMethodError on any analysis route (boot-order regression guard)" do
    # Same 0.4.0 latent bug — every analysis action instantiates
    # Core::Connection::ActiveRecordAdapter. If the require is ever
    # dropped again, every analysis tab goes down at the same time.
    # Each route should return 200 (not 500) — the status check is the
    # real regression guard; `not_to raise_error` is defensive noise
    # because Rails catches NoMethodError and returns 500, not a bare raise.
    ["duplicate_indexes", "table_sizes", "query_stats", "unused_indexes", "server_overview", "slow_queries"].each do |route|
      expect { get("/mysql_genius/#{route}") }.not_to(raise_error)
      expect(last_response.status).to(eq(200))
    end
  end
end
