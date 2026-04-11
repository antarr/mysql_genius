# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::QueryExplainer) do
  subject(:explainer) { described_class.new(connection, config) }

  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:config) do
    MysqlGenius::Core::QueryRunner::Config.new(
      blocked_tables: ["sessions"],
      masked_column_patterns: [],
      query_timeout_ms: 30_000,
    )
  end

  before do
    connection.stub_tables(["users", "posts", "sessions"])
  end

  describe "#explain" do
    it "returns a Core::Result for a valid SELECT" do
      connection.stub_query(
        /EXPLAIN SELECT/,
        columns: ["id", "select_type", "table", "type"],
        rows: [[1, "SIMPLE", "users", "ALL"]],
      )

      result = explainer.explain("SELECT id FROM users")

      expect(result).to(be_a(MysqlGenius::Core::Result))
      expect(result.columns).to(eq(["id", "select_type", "table", "type"]))
      expect(result.rows).to(eq([[1, "SIMPLE", "users", "ALL"]]))
    end

    it "raises Rejected for a non-SELECT query" do
      expect { explainer.explain("DELETE FROM users") }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /Only SELECT/))
    end

    it "raises Rejected for a blocked table" do
      expect { explainer.explain("SELECT * FROM sessions") }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /sessions/))
    end

    it "skips validation when skip_validation: true" do
      connection.stub_query(/EXPLAIN SELECT/, columns: ["id"], rows: [[1]])

      expect { explainer.explain("SELECT id FROM users", skip_validation: true) }
        .not_to(raise_error)
    end

    it "raises Truncated when the SQL appears to be cut mid-statement" do
      expect { explainer.explain("SELECT id, name FROM users WHERE", skip_validation: true) }
        .to(raise_error(MysqlGenius::Core::QueryExplainer::Truncated, /truncated/))
    end

    it "accepts SQL ending with a closing paren" do
      connection.stub_query(/EXPLAIN/, columns: ["id"], rows: [[1]])

      expect { explainer.explain("SELECT id FROM (SELECT id FROM users)", skip_validation: true) }
        .not_to(raise_error)
    end

    it "accepts SQL ending with a number" do
      connection.stub_query(/EXPLAIN/, columns: ["id"], rows: [[1]])

      expect { explainer.explain("SELECT id FROM users LIMIT 10", skip_validation: true) }
        .not_to(raise_error)
    end

    it "accepts SQL ending with a closing quote" do
      connection.stub_query(/EXPLAIN/, columns: ["id"], rows: [[1]])

      expect { explainer.explain("SELECT id FROM users WHERE name = 'alice'", skip_validation: true) }
        .not_to(raise_error)
    end

    it "strips a trailing semicolon before wrapping in EXPLAIN" do
      captured_sql = nil
      connection.stub_query(/EXPLAIN/, columns: ["id"], rows: [[1]])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      explainer.explain("SELECT id FROM users;")
      expect(captured_sql).to(eq("EXPLAIN SELECT id FROM users"))
    end
  end
end
