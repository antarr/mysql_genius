# frozen_string_literal: true

require "rails_helper"

RSpec.describe("Phase 1b latent regressions (CHANGELOG 0.4.0 / 0.4.1)", type: :request) do
  describe "Core::Connection::ActiveRecordAdapter boot-order regression (0.4.0)" do
    # The bug: lib/mysql_genius.rb did not require
    # "mysql_genius/core/connection/active_record_adapter". The concerns
    # referenced Core::Connection::ActiveRecordAdapter in every action,
    # which raised NameError at runtime. Fixed in 0.4.0 pre-publish
    # (commit 3272a80). This spec locks in the guarantee that the
    # constant is reachable via `require "mysql_genius"` alone.

    it "MysqlGenius::Core::Connection::ActiveRecordAdapter is defined after the engine boots" do
      expect(defined?(MysqlGenius::Core::Connection::ActiveRecordAdapter)).to(eq("constant"))
    end

    it "can be instantiated with an ActiveRecord connection double" do
      conn_double = instance_double("ActiveRecord::Base.connection")
      adapter = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(conn_double)
      expect(adapter).to(respond_to(:tables))
      expect(adapter).to(respond_to(:exec_query))
      expect(adapter).to(respond_to(:columns_for))
    end
  end

  describe "QueriesController#columns masked_column? NoMethodError regression (0.4.1)" do
    # The bug: Phase 1b deleted QueryExecution concern's masked_column?
    # helper. QueriesController#columns still called `masked_column?(c.name)`
    # as an instance method, which raised NoMethodError at runtime for any
    # request against a non-blocked existing table. Fixed in 0.4.1
    # (commit 27d4662) by reintroducing a private helper on the controller
    # that delegates to Core::SqlValidator.masked_column?.
    #
    # After Phase 2a, the logic moves into Core::Analysis::Columns and the
    # private helper is deleted — this spec continues to guard the failure
    # mode at the HTTP layer so it can never silently return.

    before do
      stub_connection(
        tables: ["users"],
        columns_for: {
          "users" => [
            fake_column(name: "id",            sql_type: "bigint",       type: :integer),
            fake_column(name: "email",         sql_type: "varchar(255)", type: :string),
            fake_column(name: "password_hash", sql_type: "varchar(255)", type: :string),
          ],
        },
      )
      MysqlGenius.configure { |c| c.masked_column_patterns = ["password"] }
    end

    it "does not raise NoMethodError for GET /columns on a valid table" do
      expect { get("/mysql_genius/columns?table=users") }.not_to(raise_error)
      expect(last_response.status).to(eq(200))
    end

    it "successfully filters masked columns from the response" do
      get "/mysql_genius/columns?table=users"
      expect(last_response).to(be_ok)
      json = JSON.parse(last_response.body)
      expect(json.map { |c| c["name"] }).not_to(include("password_hash"))
      expect(json.map { |c| c["name"] }).to(include("id", "email"))
    end
  end
end
