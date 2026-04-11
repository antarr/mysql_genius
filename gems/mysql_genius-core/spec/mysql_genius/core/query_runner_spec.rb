# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::QueryRunner) do
  subject(:runner) { described_class.new(connection, config) }

  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:config) do
    MysqlGenius::Core::QueryRunner::Config.new(
      blocked_tables: ["sessions"],
      masked_column_patterns: ["password", "token"],
      query_timeout_ms: 30_000,
    )
  end

  before do
    connection.stub_tables(["users", "posts", "sessions"])
    connection.stub_server_version("8.0.35")
  end

  describe "#run" do
    it "executes a valid SELECT and returns an ExecutionResult" do
      connection.stub_query(
        /SELECT.*FROM users/i,
        columns: ["id", "name"],
        rows: [[1, "Alice"]],
      )

      result = runner.run("SELECT id, name FROM users", row_limit: 25)

      expect(result).to(be_a(MysqlGenius::Core::ExecutionResult))
      expect(result.columns).to(eq(["id", "name"]))
      expect(result.rows).to(eq([[1, "Alice"]]))
      expect(result.row_count).to(eq(1))
      expect(result.execution_time_ms).to(be_a(Float))
      expect(result.execution_time_ms).to(be >= 0)
      expect(result.truncated).to(be(false))
    end

    it "raises Rejected for a non-SELECT statement" do
      expect { runner.run("DROP TABLE users", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /Only SELECT/))
    end

    it "raises Rejected for a blocked table" do
      expect { runner.run("SELECT * FROM sessions", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /sessions/))
    end

    it "raises Rejected for an empty SQL string" do
      expect { runner.run("", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /Please enter/))
    end

    it "applies the row limit to queries without an existing LIMIT" do
      captured_sql = nil
      connection.stub_query(/SELECT/, columns: ["id"], rows: [[1]])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      runner.run("SELECT id FROM users", row_limit: 25)
      expect(captured_sql).to(match(/LIMIT 25/))
    end

    it "masks columns matching configured patterns with [REDACTED]" do
      connection.stub_query(
        /SELECT/,
        columns: ["id", "encrypted_password", "email"],
        rows: [[1, "hash123", "alice@example.com"]],
      )

      result = runner.run("SELECT id, encrypted_password, email FROM users", row_limit: 25)

      expect(result.rows).to(eq([[1, "[REDACTED]", "alice@example.com"]]))
    end

    it "masks multiple columns matching different patterns" do
      connection.stub_query(
        /SELECT/,
        columns: ["id", "api_token", "reset_password_digest"],
        rows: [[1, "tok_abc", "digest_xyz"]],
      )

      result = runner.run("SELECT id, api_token, reset_password_digest FROM users", row_limit: 25)

      expect(result.rows).to(eq([[1, "[REDACTED]", "[REDACTED]"]]))
    end

    it "sets truncated=true when row count reaches the row_limit" do
      connection.stub_query(
        /SELECT/,
        columns: ["id"],
        rows: [[1], [2], [3]],
      )

      result = runner.run("SELECT id FROM users", row_limit: 3)

      expect(result.truncated).to(be(true))
    end

    it "wraps SELECT with MAX_EXECUTION_TIME hint on MySQL" do
      captured_sql = nil
      connection.stub_server_version("8.0.35")
      connection.stub_query(/SELECT/, columns: ["id"], rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      runner.run("SELECT id FROM users", row_limit: 25)
      expect(captured_sql).to(include("MAX_EXECUTION_TIME(30000)"))
    end

    it "wraps SELECT with SET STATEMENT max_statement_time on MariaDB" do
      captured_sql = nil
      connection.stub_server_version("10.11.5-MariaDB")
      connection.stub_query(/SELECT/, columns: ["id"], rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      runner.run("SELECT id FROM users", row_limit: 25)
      expect(captured_sql).to(match(/SET STATEMENT max_statement_time=30 FOR/))
    end

    it "raises Timeout when the database reports a statement timeout" do
      connection.stub_query(
        /SELECT/,
        raises: StandardError.new("Query execution was interrupted, max_statement_time exceeded"),
      )

      expect { runner.run("SELECT id FROM users", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Timeout))
    end

    it "raises Timeout when the error message mentions max_execution_time" do
      connection.stub_query(
        /SELECT/,
        raises: StandardError.new("max_execution_time exceeded"),
      )

      expect { runner.run("SELECT id FROM users", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Timeout))
    end

    it "propagates non-timeout database errors" do
      connection.stub_query(
        /SELECT/,
        raises: StandardError.new("ERROR 1146 (42S02): Table 'app.nonexistent' doesn't exist"),
      )

      expect { runner.run("SELECT id FROM users", row_limit: 25) }
        .to(raise_error(StandardError, /nonexistent/))
    end
  end
end
