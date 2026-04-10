# frozen_string_literal: true

MysqlGenius.configure do |config|
  # --- Authentication ---
  # Lambda that receives the controller instance. Return true to allow access.
  # Default: allows everyone. Use route constraints for most cases.
  # config.authenticate = ->(controller) { controller.current_user&.admin? }

  # To use current_user or other app helpers, inherit from ApplicationController:
  # config.base_controller = "ApplicationController"

  # --- Tables ---
  # Tables featured at the top of the visual builder dropdown (optional).
  # config.featured_tables = %w[users posts comments]

  # Tables blocked from querying (defaults: sessions, schema_migrations, ar_internal_metadata).
  # config.blocked_tables += %w[oauth_tokens api_keys]

  # Column patterns to redact with [REDACTED] in results (case-insensitive substring match).
  # config.masked_column_patterns = %w[password secret digest token ssn]

  # Default columns checked in the visual builder per table (optional).
  # config.default_columns = {
  #   "users" => %w[id name email created_at],
  #   "posts" => %w[id title user_id published_at]
  # }

  # --- Query Safety ---
  # config.max_row_limit = 1000       # Hard cap on rows returned
  # config.default_row_limit = 25     # Default when no limit specified
  # config.query_timeout_ms = 30_000  # 30 second timeout

  # --- Slow Query Monitoring ---
  # Requires Redis. Set to nil to disable.
  # config.redis_url = ENV["REDIS_URL"]
  # config.slow_query_threshold_ms = 250

  # --- Audit Logging ---
  # Set to nil to disable. Logs query executions, rejections, and errors.
  # config.audit_logger = Logger.new(Rails.root.join("log", "mysql_genius.log"))

  # --- AI Features (optional) ---
  # Supports any OpenAI-compatible API: OpenAI, Azure OpenAI, Ollama, or a custom client.
  # config.ai_endpoint = "https://api.openai.com/v1/chat/completions"
  # config.ai_api_key = ENV["OPENAI_API_KEY"]
  # config.ai_model = "gpt-4o"
  # config.ai_auth_style = :bearer  # :bearer for OpenAI/Ollama, :api_key for Azure

  # Domain context helps the AI understand your schema and generate better queries.
  # config.ai_system_context = <<~CONTEXT
  #   This is an e-commerce database.
  #   - `users` stores customer accounts.
  #   - `orders` tracks purchases, linked to users via `user_id`.
  #   - Soft-deleted records have `deleted_at IS NOT NULL`.
  # CONTEXT

  # --- Multi-Database ---
  # Per-database overrides (YAML config in config/mysql_genius.yml is preferred).
  # config.database(:analytics) do |db|
  #   db.blocked_tables = %w[raw_events etl_staging]
  #   db.query_timeout_ms = 60_000
  # end
end
