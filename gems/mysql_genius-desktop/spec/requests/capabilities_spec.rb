# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"

RSpec.describe("Capability-based template gating", type: :request) do
  it "does not render the Slow Queries tab button" do
    get "/"
    expect(last_response.body).not_to(include('data-tab="slow">Slow Queries'))
  end

  it "does not render the tab_slow_queries partial" do
    get "/"
    expect(last_response.body).not_to(include('id="tab-slow"'))
  end

  it "does not render the Top-5 Slow Queries dashboard card" do
    get "/"
    expect(last_response.body).not_to(include('id="dash-slow-tbody"'))
  end

  it "does not render the Root Cause button in the Server tab" do
    @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.new(
      enabled: true,
      endpoint: "https://x/y",
      api_key: "k",
      model: "",
      auth_style: :bearer,
      system_context: "",
      domain_context: "",
    ))
    get "/"
    expect(last_response.body).not_to(include("server-root-cause"))
  end

  it "does not render the Anomaly Detection button in the Server tab" do
    @test_config.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.new(
      enabled: true,
      endpoint: "https://x/y",
      api_key: "k",
      model: "",
      auth_style: :bearer,
      system_context: "",
      domain_context: "",
    ))
    get "/"
    expect(last_response.body).not_to(include("server-anomaly"))
  end

  it "starts loaded.slow as true so checkAllLoaded does not wait for slow queries" do
    get "/"
    expect(last_response.body).to(include("slow: true"))
  end

  it "still renders the normal Dashboard and Query Stats tabs" do
    get "/"
    expect(last_response.body).to(include('data-tab="dashboard">Dashboard'))
    expect(last_response.body).to(include('data-tab="qstats">Query Stats'))
    expect(last_response.body).to(include('data-tab="server">Server'))
  end
end
# rubocop:enable RSpec/InstanceVariable
