# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"

RSpec.describe("Session-token auth", type: :request) do
  describe "with valid cookie" do
    it "allows GET /columns through" do
      @fake_adapter.stub_tables(["users"])
      @fake_adapter.stub_columns_for("users", [
        MysqlGenius::Core::ColumnDefinition.new(name: "id", sql_type: "bigint", type: :integer, null: false, default: nil, primary_key: true),
      ])
      get "/columns?table=users"
      expect(last_response.status).to(eq(200))
    end
  end

  describe "without cookie" do
    before do
      clear_cookies
    end

    it "allows GET / without a cookie (exempt)" do
      get "/"
      expect(last_response.status).to(eq(200))
    end

    it "sets the mg_session cookie on GET /" do
      get "/"
      expect(last_response.headers["Set-Cookie"]).to(include("mg_session="))
    end

    it "blocks POST /execute without a cookie" do
      post "/execute", sql: "SELECT 1"
      expect(last_response.status).to(eq(403))
      body = JSON.parse(last_response.body)
      expect(body["error"]).to(eq("Forbidden"))
    end

    it "blocks GET /columns without a cookie" do
      get "/columns?table=users"
      expect(last_response.status).to(eq(403))
    end

    it "blocks GET /api/profiles without a cookie" do
      get "/api/profiles"
      expect(last_response.status).to(eq(403))
    end
  end

  describe "with wrong cookie" do
    before do
      clear_cookies
      set_cookie("mg_session=wrong-token")
    end

    it "blocks requests with an invalid token" do
      get "/columns?table=users"
      expect(last_response.status).to(eq(403))
    end
  end
end
# rubocop:enable RSpec/InstanceVariable
