# frozen_string_literal: true

require "rails_helper"

RSpec.describe("GET /mysql_genius/", type: :request) do
  before do
    stub_connection(tables: ["users", "orders", "products"])
  end

  it "returns 200" do
    get "/mysql_genius/"
    expect(last_response).to(be_ok)
  end

  it "renders the dashboard HTML" do
    get "/mysql_genius/"
    expect(last_response.content_type).to(include("text/html"))
    expect(last_response.body).to(include("mg-tab"))
  end

  it "respects blocked_tables when building the table lists" do
    MysqlGenius.configure { |c| c.blocked_tables = ["orders"] }
    get "/mysql_genius/"
    expect(last_response).to(be_ok)
    # The tables dropdown should not contain the blocked table
    expect(last_response.body).not_to(match(/<option value="orders">/))
  end

  it "respects featured_tables when set" do
    MysqlGenius.configure { |c| c.featured_tables = ["users"] }
    get "/mysql_genius/"
    expect(last_response).to(be_ok)
    expect(last_response.body).to(match(/<optgroup label="Featured">.*<option value="users">/m))
    expect(last_response.body).to(include('<optgroup label="All Tables">'))
  end
end
