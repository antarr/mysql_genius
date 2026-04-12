# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"

RSpec.describe("GET /", type: :request) do
  it "returns 200 and renders the dashboard page" do
    @fake_adapter.stub_tables(["orders", "users"])
    get "/"
    expect(last_response.status).to(eq(200))
    expect(last_response.body).to(include("MySQLGenius"))
    expect(last_response.body).to(include('data-tab="dashboard">Dashboard'))
  end

  it "hides the Slow Queries tab because the sidecar does not report :slow_queries as a capability" do
    get "/"
    expect(last_response.body).not_to(include('data-tab="slow">Slow Queries'))
  end

  it "hides the Root Cause and Anomaly Detection buttons in the Server tab" do
    @test_config.ai.instance_variable_set(:@endpoint, "https://api.example.com/v1/chat/completions")
    @test_config.ai.instance_variable_set(:@api_key,  "test-key")
    get "/"
    expect(last_response.body).not_to(include("server-root-cause"))
    expect(last_response.body).not_to(include("server-anomaly"))
  end

  it "omits the Top-5 Slow Queries card on the Dashboard tab" do
    get "/"
    expect(last_response.body).not_to(include("dash-slow-tbody"))
  end

  it "excludes stubbed blocked tables from @all_tables" do
    @test_config.instance_variable_set(:@security, MysqlGenius::Desktop::Config::SecurityConfig.from_hash({ "blocked_tables" => ["schema_migrations"] }))
    @fake_adapter.stub_tables(["orders", "schema_migrations", "users"])
    get "/"
    expect(last_response.status).to(eq(200))
    expect(last_response.body).not_to(include(">schema_migrations<"))
  end
end
# rubocop:enable RSpec/InstanceVariable
