# frozen_string_literal: true

# rubocop:disable RSpec/InstanceVariable
require "rack_helper"
require "tmpdir"

RSpec.describe("Profile API routes", type: :request) do
  around do |example|
    Dir.mktmpdir do |dir|
      @config_path = File.join(dir, "mg.yml")
      File.write(@config_path, YAML.dump({
        "version" => 2,
        "default_profile" => "prod",
        "profiles" => [
          { "name" => "prod", "mysql" => { "host" => "db.prod.com", "username" => "readonly", "database" => "app_prod" } },
          { "name" => "staging", "mysql" => { "host" => "db.staging.com", "username" => "readonly", "database" => "app_staging" } },
        ],
      }))
      example.run
    end
  end

  before do
    @test_config.instance_variable_set(:@source_path, @config_path)
    @test_config.instance_variable_set(:@profiles, [
      MysqlGenius::Desktop::Config::ProfileConfig.new(name: "prod", mysql: MysqlGenius::Desktop::Config::MysqlConfig.from_hash({ "host" => "db.prod.com", "username" => "readonly", "database" => "app_prod" })),
      MysqlGenius::Desktop::Config::ProfileConfig.new(name: "staging", mysql: MysqlGenius::Desktop::Config::MysqlConfig.from_hash({ "host" => "db.staging.com", "username" => "readonly", "database" => "app_staging" })),
    ])
    @test_config.instance_variable_set(:@default_profile, "prod")
    MysqlGenius::Desktop::App.set(:current_profile_name, "prod")
  end

  describe "GET /api/profiles" do
    it "returns profiles list with current profile name" do
      get "/api/profiles"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["profiles"].length).to(eq(2))
      expect(body["current"]).to(eq("prod"))
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
      new_session = instance_double(MysqlGenius::Desktop::ActiveSession)
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:new).and_return(new_session))

      post "/api/profiles/staging/connect"
      expect(last_response.status).to(eq(200))
      body = JSON.parse(last_response.body)
      expect(body["success"]).to(be(true))
      expect(body["profile"]).to(eq("staging"))
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
end
# rubocop:enable RSpec/InstanceVariable
