# frozen_string_literal: true

require "rack_helper"

RSpec.describe("GET /connections", type: :request) do
  it "returns 200 and renders the connection manager page" do
    get "/connections"
    expect(last_response.status).to(eq(200))
    expect(last_response.body).to(include("Connection Manager"))
    expect(last_response.body).to(include("mg-profile-table"))
  end

  it "is exempt from auth (sets cookie like GET /)" do
    clear_cookies
    get "/connections"
    expect(last_response.status).to(eq(200))
    expect(last_response.headers["Set-Cookie"]).to(include("mg_session="))
  end

  it "renders through the layout (has CSS)" do
    get "/connections"
    expect(last_response.body).to(include("mg-container"))
    expect(last_response.body).to(include("<style>"))
  end
end
