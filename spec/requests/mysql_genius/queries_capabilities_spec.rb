# frozen_string_literal: true

require "rails_helper"

RSpec.describe("GET /mysql_genius/primary/ (capability rendering)", type: :request) do
  before do
    stub_connection(
      tables: ["users"],
      columns_for: { "users" => [fake_column(name: "id", sql_type: "bigint", type: :integer, null: false)] },
    )
  end

  it "renders the Slow Queries tab button (Rails adapter always reports :slow_queries as a capability)" do
    get "/mysql_genius/primary/"
    expect(last_response).to(be_ok)
    expect(last_response.body).to(include('data-tab="slow">Slow Queries'))
  end

  it "renders the Root Cause button when AI is enabled" do
    MysqlGenius.configure do |c|
      c.ai_endpoint = "https://example.com/v1/chat/completions"
      c.ai_api_key  = "test-key"
    end
    get "/mysql_genius/primary/"
    expect(last_response.body).to(include("server-root-cause"))
  end
end
