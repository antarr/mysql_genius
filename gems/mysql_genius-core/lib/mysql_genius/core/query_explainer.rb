# frozen_string_literal: true

module MysqlGenius
  module Core
    # Runs EXPLAIN against a SELECT query via a Core::Connection. Optionally
    # skips SQL validation (used for explaining captured slow queries from
    # mysql's own logs where the exact text may include references to
    # otherwise-blocked tables).
    #
    # Rejects obviously-truncated SQL — captured slow queries from the
    # slow query log are capped at ~2000 characters, so if the last
    # character doesn't look like a valid terminator we refuse to try.
    # This avoids confusing EXPLAIN errors from partial statements.
    #
    # Reuses Core::QueryRunner::Rejected for validation failures so
    # callers can rescue one error type for both runners.
    class QueryExplainer
      class Truncated < Core::Error; end

      def initialize(connection, config)
        @connection = connection
        @config = config
      end

      def explain(sql, skip_validation: false)
        unless skip_validation
          error = SqlValidator.validate(
            sql,
            blocked_tables: @config.blocked_tables,
            connection: @connection,
          )
          raise QueryRunner::Rejected, error if error
        end

        clean_sql = sql.gsub(/;\s*\z/, "")

        unless looks_complete?(clean_sql)
          raise Truncated, "This query appears to be truncated and cannot be explained."
        end

        @connection.exec_query("EXPLAIN #{clean_sql}")
      end

      private

      # Heuristic: SQL ends with a value-like token (identifier, number, closing
      # paren/bracket, or closing quote). A trailing SQL keyword such as WHERE,
      # AND, OR, ON, JOIN, SET, HAVING, or a comma/operator means the statement
      # was cut before its next token.
      TRAILING_KEYWORD_PATTERN = /\b(WHERE|AND|OR|ON|JOIN|INNER|OUTER|LEFT|RIGHT|CROSS|HAVING|SET|BETWEEN|LIKE|IN|NOT|IS|FROM|SELECT|GROUP|ORDER|LIMIT|OFFSET|UNION|EXCEPT|INTERSECT)\s*$/i

      def looks_complete?(sql)
        return false if sql.match?(TRAILING_KEYWORD_PATTERN)
        return false if sql.match?(%r{[,=<>!(+\-*/]\s*$})

        sql.match?(/[\w'"`)\]]\s*$/)
      end
    end
  end
end
