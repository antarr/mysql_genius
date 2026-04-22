# frozen_string_literal: true

require "rails_helper"

RSpec.describe("Multi-database routing", type: :request) do
  describe "root redirect" do
    it "redirects /mysql_genius/ to the default database when registry is non-empty" do
      stub_connection(tables: [])
      get "/mysql_genius/"
      expect(last_response).to(be_redirect)
      expect(last_response.location).to(end_with("/mysql_genius/primary"))
    end

    it "redirects /mysql_genius/ to /setup when no databases are registered" do
      stub_empty_registry
      get "/mysql_genius/"
      expect(last_response).to(be_redirect)
      expect(last_response.location).to(end_with("/mysql_genius/setup"))
    end
  end

  describe "legacy path compatibility redirect" do
    before { stub_connection(tables: []) }

    it "redirects unscoped dashboard paths into the default database's scope" do
      get "/mysql_genius/slow_queries"
      expect(last_response).to(be_redirect)
      expect(last_response.location).to(end_with("/mysql_genius/primary/slow_queries"))
    end

    it "redirects unscoped analysis paths" do
      get "/mysql_genius/unused_indexes"
      expect(last_response).to(be_redirect)
      expect(last_response.location).to(end_with("/mysql_genius/primary/unused_indexes"))
    end

    it "does not redirect already-scoped paths to a valid database" do
      stub_connection(tables: [], allow_unmatched_exec_query: true)
      get "/mysql_genius/primary/unused_indexes"
      expect(last_response).not_to(be_redirect)
    end
  end

  describe "unknown database_id" do
    before { stub_connection(tables: []) }

    it "falls through the constrained scope to the legacy redirect" do
      # Because of the constraints: lambda on the scope, an unknown database_id
      # doesn't match the nested scope at all. It falls to the legacy catch-all
      # which prepends the default database key — which then 404s on the unknown
      # sub-path inside the (valid) primary scope.
      get "/mysql_genius/nope/slow_queries"
      # First hop: redirect into primary's scope, prepending "nope" as a legacy path.
      expect(last_response).to(be_redirect)
      expect(last_response.location).to(end_with("/mysql_genius/primary/nope/slow_queries"))
    end
  end

  describe "setup page" do
    it "renders when the registry is empty" do
      stub_empty_registry
      get "/mysql_genius/setup"
      expect(last_response).to(be_ok)
      expect(last_response.body).to(include("No MySQL connection found"))
      expect(last_response.body).to(include("config/database.yml"))
    end

    it "skips the database before_action (does not require a database_id)" do
      # The action_name == "setup" guard bypasses set_current_database entirely,
      # so the setup page should render even with no registry and no @database.
      stub_empty_registry
      expect { get("/mysql_genius/setup") }.not_to(raise_error)
    end
  end

  describe "database selector partial" do
    it "is hidden when only one database is registered" do
      stub_connection(tables: [])
      get "/mysql_genius/primary"
      expect(last_response.body).not_to(include("mg-db-selector"))
    end

    it "renders a dropdown when multiple databases are registered" do
      stub_two_database_registry
      get "/mysql_genius/primary"
      expect(last_response.body).to(include("mg-db-selector"))
      expect(last_response.body).to(include(">primary<"))
      expect(last_response.body).to(include(">analytics<"))
    end
  end

  # ---- helpers ----

  def stub_empty_registry
    empty = double("MysqlGenius::DatabaseRegistry",
      keys: [],
      default_key: nil,
      empty?: true,
      size: 0)
    allow(empty).to(receive(:each))
    allow(empty).to(receive(:[]).and_return(nil))
    allow(empty).to(receive(:fetch)) { |k| raise KeyError, "Unknown: #{k}" }
    allow(MysqlGenius).to(receive(:database_registry).and_return(empty))
  end

  def stub_two_database_registry
    connection = double("AR::Base.connection")
    allow(connection).to(receive_messages(
      tables: [],
      current_database: "test_db",
      exec_query: fake_result,
    ))
    allow(connection).to(receive(:quote) { |v| "'#{v}'" })
    allow(connection).to(receive(:quote_table_name) { |n| "`#{n}`" })
    allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))

    db_factory = lambda do |key|
      double("MysqlGenius::Database",
        key: key,
        label: key,
        reader?: false,
        adapter_name: "mysql2",
        ar_connection: connection,
        connection: MysqlGenius::Core::Connection::ActiveRecordAdapter.new(connection))
    end
    primary = db_factory.call("primary")
    analytics = db_factory.call("analytics")
    map = { "primary" => primary, "analytics" => analytics }

    registry = double("MysqlGenius::DatabaseRegistry",
      keys: ["primary", "analytics"],
      default_key: "primary",
      empty?: false,
      size: 2)
    allow(registry).to(receive(:each)) { |&blk| map.each_value(&blk) }
    allow(registry).to(receive(:[])) { |k| map[k.to_s] }
    allow(registry).to(receive(:fetch)) do |k|
      map[k.to_s] || raise(KeyError, "Unknown: #{k}")
    end
    allow(MysqlGenius).to(receive(:database_registry).and_return(registry))
  end
end
