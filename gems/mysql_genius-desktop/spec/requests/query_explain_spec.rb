# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"

RSpec.describe("POST /explain", type: :request) do
  before do
    @fake_adapter.stub_tables(["users"])
  end

  it "returns 200 with columns and rows from EXPLAIN" do
    @fake_adapter.stub_query(/EXPLAIN SELECT.*FROM users/, columns: ["id", "select_type", "table"], rows: [[1, "SIMPLE", "users"]])
    post "/explain", sql: "SELECT id FROM users"
    expect(last_response.status).to(eq(200))
    body = JSON.parse(last_response.body)
    expect(body["columns"]).to(eq(["id", "select_type", "table"]))
    expect(body["rows"]).to(eq([[1, "SIMPLE", "users"]]))
  end

  it "returns 422 when SQL is rejected" do
    post "/explain", sql: "DROP TABLE users"
    expect(last_response.status).to(eq(422))
    body = JSON.parse(last_response.body)
    expect(body["error"]).to(match(/SELECT|not allowed/i))
  end

  it "returns 422 when SQL is truncated (ends with a trailing keyword)" do
    post "/explain", sql: "SELECT id FROM users WHERE"
    expect(last_response.status).to(eq(422))
    body = JSON.parse(last_response.body)
    expect(body["error"]).to(include("truncated"))
  end
end
# rubocop:enable RSpec/InstanceVariable
