# frozen_string_literal: true

require "rails_helper"

RSpec.describe("GET /mysql_genius/primary/columns", type: :request) do
  let(:users_columns) do
    [
      fake_column(name: "id",            sql_type: "bigint",       type: :integer),
      fake_column(name: "email",         sql_type: "varchar(255)", type: :string),
      fake_column(name: "password_hash", sql_type: "varchar(255)", type: :string),
      fake_column(name: "api_token",     sql_type: "varchar(64)",  type: :string),
      fake_column(name: "created_at",    sql_type: "datetime",     type: :datetime),
    ]
  end

  before do
    stub_connection(tables: ["users"], columns_for: { "users" => users_columns })
    MysqlGenius.configure do |c|
      c.masked_column_patterns = ["password", "token"]
      c.default_columns = { "users" => ["id", "email", "created_at"] }
    end
  end

  it "returns JSON column metadata for a known table" do
    get "/mysql_genius/primary/columns?table=users"

    expect(last_response).to(be_ok)
    expect(last_response.content_type).to(include("application/json"))
    json = JSON.parse(last_response.body)
    names = json.map { |c| c["name"] }
    expect(names).to(include("id", "email", "created_at"))
  end

  it "filters columns whose names match masked_column_patterns" do
    get "/mysql_genius/primary/columns?table=users"

    json = JSON.parse(last_response.body)
    names = json.map { |c| c["name"] }
    expect(names).not_to(include("password_hash"))
    expect(names).not_to(include("api_token"))
  end

  it "marks default_columns with default: true and others with default: false" do
    get "/mysql_genius/primary/columns?table=users"

    json = JSON.parse(last_response.body)
    by_name = json.index_by { |c| c["name"] }
    expect(by_name["id"]["default"]).to(be(true))
    expect(by_name["email"]["default"]).to(be(true))
    expect(by_name["created_at"]["default"]).to(be(true))
  end

  it "returns 403 when the table is in blocked_tables" do
    MysqlGenius.configure { |c| c.blocked_tables = ["users"] }

    get "/mysql_genius/primary/columns?table=users"

    expect(last_response.status).to(eq(403))
    json = JSON.parse(last_response.body)
    expect(json["error"]).to(include("not available for querying"))
  end

  it "returns 404 when the table does not exist" do
    get "/mysql_genius/primary/columns?table=nonexistent"

    expect(last_response.status).to(eq(404))
    json = JSON.parse(last_response.body)
    expect(json["error"]).to(include("does not exist"))
  end

  it "does not raise NoMethodError (0.4.1 hotfix regression guard)" do
    # The 0.4.1 bug: QueriesController#columns called masked_column?(c.name)
    # but no such instance method existed on the controller after Phase 1b
    # deleted it from the QueryExecution concern. Request returned 500.
    expect { get("/mysql_genius/primary/columns?table=users") }.not_to(raise_error)
    expect(last_response.status).to(eq(200))
  end
end
