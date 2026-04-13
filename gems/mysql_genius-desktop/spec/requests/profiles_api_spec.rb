# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"

RSpec.describe("Profile API routes", type: :request) do
  before do
    @test_database.add_profile({
      "name" => "prod",
      "host" => "db.prod.com",
      "username" => "readonly",
      "database_name" => "app_prod",
    })
    @test_database.add_profile({
      "name" => "staging",
      "host" => "db.staging.com",
      "username" => "readonly",
      "database_name" => "app_staging",
    })
    MysqlGenius::Desktop::App.set(:current_profile_name, "prod")
  end

  describe "GET /api/profiles" do
    it "returns profiles list with current profile name" do
      get "/api/profiles"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["profiles"].length).to(eq(2))
      expect(body["current"]).to(eq("prod"))
      expect(body["profiles"].first["name"]).to(eq("prod"))
      expect(body["profiles"].first["mysql"]["host"]).to(eq("db.prod.com"))
      expect(body["profiles"].first["mysql"]["database"]).to(eq("app_prod"))
    end
  end

  describe "POST /api/profiles" do
    it "adds a new profile and returns updated list" do
      post "/api/profiles", { name: "dev", mysql: { host: "localhost", username: "root", database: "app_dev" } }.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["profiles"].length).to(eq(3))
    end

    it "returns 409 for duplicate profile name" do
      post "/api/profiles", { name: "prod", mysql: { host: "h", username: "u", database: "d" } }.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to(eq(409))
    end
  end

  describe "PUT /api/profiles/:name" do
    it "updates an existing profile" do
      put "/api/profiles/prod", { mysql: { host: "new-host.com", username: "readonly", database: "app_prod" } }.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      updated = body["profiles"].find { |p| p["name"] == "prod" }
      expect(updated["mysql"]["host"]).to(eq("new-host.com"))
    end

    it "returns 404 for unknown profile" do
      put "/api/profiles/unknown", { mysql: { host: "h", username: "u", database: "d" } }.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to(eq(404))
    end
  end

  describe "DELETE /api/profiles/:name" do
    it "deletes a non-active profile" do
      delete "/api/profiles/staging"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["profiles"].length).to(eq(1))
    end

    it "returns 422 when trying to delete the active profile" do
      delete "/api/profiles/prod"
      expect(last_response.status).to(eq(422))
    end
  end

  describe "POST /api/test_connection" do
    it "tests a connection and returns success/version" do
      adapter = instance_double(MysqlGenius::Core::Connection::TrilogyAdapter)
      allow(adapter).to(receive(:exec_query).and_return(instance_double(MysqlGenius::Core::Result, rows: [["8.0.35"]])))
      allow(adapter).to(receive(:close))
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:open_adapter_for).and_return(adapter))

      post "/api/test_connection", { mysql: { host: "db.prod.com", username: "readonly", database: "app_prod" } }.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["success"]).to(be(true))
      expect(body["version"]).to(eq("8.0.35"))
    end
  end

  describe "POST /api/profiles/:name/connect" do
    it "switches the active connection to the named profile" do
      new_session = instance_double(MysqlGenius::Desktop::ActiveSession, tunnel_port: nil)
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:new).and_return(new_session))

      post "/api/profiles/staging/connect"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["success"]).to(be(true))
      expect(body["profile"]).to(eq("staging"))
    end

    it "returns 404 for unknown profile" do
      post "/api/profiles/unknown/connect"
      expect(last_response.status).to(eq(404))
    end

    it "returns 422 when the connection fails" do
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:new).and_raise(
        MysqlGenius::Desktop::ActiveSession::ConnectError, "connection refused"
      ))

      post "/api/profiles/staging/connect"
      expect(last_response.status).to(eq(422))
      body = JSON.parse(last_response.body)
      expect(body["error"]).to(include("connection refused"))
    end
  end

  describe "GET /api/ai_config" do
    it "returns empty hash when no AI config set" do
      get "/api/ai_config"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body).to(eq({}))
    end

    it "returns stored AI config" do
      @test_database.set_ai_config({ "endpoint" => "https://api.example.com", "api_key" => "sk-123", "model" => "gpt-4" })
      get "/api/ai_config"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["endpoint"]).to(eq("https://api.example.com"))
      expect(body["model"]).to(eq("gpt-4"))
    end
  end

  describe "PUT /api/ai_config" do
    it "saves AI config and reloads into running app" do
      put "/api/ai_config", { endpoint: "https://api.example.com", api_key: "sk-123", model: "gpt-4" }.to_json, "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["success"]).to(be(true))

      stored = @test_database.get_ai_config
      expect(stored["endpoint"]).to(eq("https://api.example.com"))
      expect(stored["model"]).to(eq("gpt-4"))
    end
  end
end
# rubocop:enable RSpec/InstanceVariable
