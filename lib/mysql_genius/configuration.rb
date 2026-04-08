module MysqlGenius
  class Configuration
    # Tables to feature in the visual builder dropdown (array of strings).
    # When empty, all non-blocked tables are shown.
    attr_accessor :featured_tables

    # Tables that must never be queried (auth, sessions, internal Rails tables).
    attr_accessor :blocked_tables

    # Column name patterns to mask with [REDACTED] in query results.
    # Matched case-insensitively via String#include?.
    attr_accessor :masked_column_patterns

    # Default columns to check in the visual builder, keyed by table name.
    # Example: { "users" => %w[id name email created_at] }
    attr_accessor :default_columns

    # Maximum rows a single query can return.
    attr_accessor :max_row_limit

    # Default row limit when none is specified.
    attr_accessor :default_row_limit

    # Query timeout in milliseconds.
    attr_accessor :query_timeout_ms

    # Proc that receives the controller instance and returns true if the user
    # is authorized. Example:
    #   config.authenticate = ->(controller) { controller.current_user&.admin? }
    attr_accessor :authenticate

    # AI configuration — set to nil to disable AI features entirely.
    # Must respond to :call(messages:, response_format:, temperature:)
    # and return a Hash with "choices" in OpenAI-compatible format,
    # OR set ai_endpoint + ai_api_key for a direct OpenAI-compatible HTTP API.
    attr_accessor :ai_client
    attr_accessor :ai_endpoint
    attr_accessor :ai_api_key

    # Custom system prompt prepended to AI suggestions. Use this to describe
    # your domain, table relationships, and naming conventions.
    attr_accessor :ai_system_context

    # Slow query threshold in milliseconds. Queries slower than this are logged.
    attr_accessor :slow_query_threshold_ms

    # Redis URL for slow query storage. Set to nil to disable slow query monitoring.
    attr_accessor :redis_url

    # Logger instance for audit logging. Defaults to a file logger.
    # Set to nil to disable audit logging.
    attr_accessor :audit_logger

    def initialize
      @featured_tables = []
      @blocked_tables = %w[
        sessions
        ar_internal_metadata
        schema_migrations
      ]
      @masked_column_patterns = %w[password secret digest token]
      @default_columns = {}
      @max_row_limit = 1000
      @default_row_limit = 25
      @query_timeout_ms = 30_000
      @authenticate = ->(controller) { true }
      @ai_client = nil
      @ai_endpoint = nil
      @ai_api_key = nil
      @ai_system_context = nil
      @slow_query_threshold_ms = 250
      @redis_url = nil
      @audit_logger = nil
    end

    def ai_enabled?
      ai_client.present? || (ai_endpoint.present? && ai_api_key.present?)
    end
  end
end
