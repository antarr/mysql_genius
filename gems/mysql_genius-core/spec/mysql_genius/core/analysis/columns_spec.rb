# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"
require "mysql_genius/core/analysis/columns"
require "mysql_genius/core/connection/fake_adapter"

RSpec.describe(MysqlGenius::Core::Analysis::Columns) do
  subject(:service) do
    described_class.new(
      connection,
      blocked_tables: [],
      masked_column_patterns: ["password", "token"],
      default_columns: { "users" => ["id", "email", "created_at"] },
    )
  end

  let(:users_columns) do
    [
      MysqlGenius::Core::ColumnDefinition.new(name: "id",            sql_type: "bigint",       type: :integer,  null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email",         sql_type: "varchar(255)", type: :string,   null: false, default: nil, primary_key: false),
      MysqlGenius::Core::ColumnDefinition.new(name: "password_hash", sql_type: "varchar(255)", type: :string,   null: false, default: nil, primary_key: false),
      MysqlGenius::Core::ColumnDefinition.new(name: "api_token",     sql_type: "varchar(64)",  type: :string,   null: true,  default: nil, primary_key: false),
      MysqlGenius::Core::ColumnDefinition.new(name: "created_at",    sql_type: "datetime",     type: :datetime, null: false, default: nil, primary_key: false),
    ]
  end

  let(:connection) do
    conn = MysqlGenius::Core::Connection::FakeAdapter.new
    conn.stub_tables(["users"])
    conn.stub_columns_for("users", users_columns)
    conn
  end

  describe "#call(table:)" do
    context "when the table exists and is not blocked" do
      it "returns :ok status with visible columns" do
        result = service.call(table: "users")
        expect(result.status).to(eq(:ok))
        expect(result.error_message).to(be_nil)
      end

      it "filters columns whose names match masked_column_patterns" do
        result = service.call(table: "users")
        names = result.columns.map { |c| c[:name] }
        expect(names).to(include("id", "email", "created_at"))
        expect(names).not_to(include("password_hash"))
        expect(names).not_to(include("api_token"))
      end

      it "marks default_columns with default: true" do
        result = service.call(table: "users")
        by_name = result.columns.to_h { |c| [c[:name], c] }
        expect(by_name["id"][:default]).to(be(true))
        expect(by_name["email"][:default]).to(be(true))
        expect(by_name["created_at"][:default]).to(be(true))
      end

      it "when default_columns has no entry for the table, marks ALL as default: true" do
        service_without_defaults = described_class.new(
          connection,
          blocked_tables: [],
          masked_column_patterns: [],
          default_columns: {},
        )
        result = service_without_defaults.call(table: "users")
        expect(result.columns.map { |c| c[:default] }).to(all(be(true)))
      end

      it "returns type as a string (matching the controller's JSON shape)" do
        result = service.call(table: "users")
        id = result.columns.find { |c| c[:name] == "id" }
        expect(id[:type]).to(eq("integer"))
      end
    end

    context "when the table is in blocked_tables" do
      subject(:blocked_service) do
        described_class.new(
          connection,
          blocked_tables: ["users"],
          masked_column_patterns: [],
          default_columns: {},
        )
      end

      it "returns :blocked status with an error message" do
        result = blocked_service.call(table: "users")
        expect(result.status).to(eq(:blocked))
        expect(result.columns).to(be_nil)
        expect(result.error_message).to(include("not available for querying"))
        expect(result.error_message).to(include("users"))
      end
    end

    context "when the table does not exist" do
      it "returns :not_found status with an error message" do
        result = service.call(table: "nonexistent")
        expect(result.status).to(eq(:not_found))
        expect(result.columns).to(be_nil)
        expect(result.error_message).to(include("does not exist"))
        expect(result.error_message).to(include("nonexistent"))
      end
    end
  end
end
