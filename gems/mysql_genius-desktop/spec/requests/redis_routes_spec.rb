# frozen_string_literal: true

require "rack_helper"

RSpec.describe("Redis-backed routes (intentionally unregistered)", type: :request) do
  it "returns 404 for GET /slow_queries" do
    get "/slow_queries"
    expect(last_response.status).to(eq(404))
  end

  it "returns 404 for POST /anomaly_detection" do
    post "/anomaly_detection"
    expect(last_response.status).to(eq(404))
  end

  it "returns 404 for POST /root_cause" do
    post "/root_cause"
    expect(last_response.status).to(eq(404))
  end
end
