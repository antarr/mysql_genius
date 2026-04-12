# frozen_string_literal: true

require "sinatra/base"
require "tilt"
require "json"
require "mysql_genius/core"
require "mysql_genius/desktop/paths"
require "mysql_genius/desktop/profile_manager"
require "mysql_genius/desktop/session_swapper"

module MysqlGenius
  module Desktop
    class App < Sinatra::Base
      set :views, File.join(MysqlGenius::Core.views_path, "mysql_genius/queries")
      set :server, "puma"
      set :quiet, true
      set :mysql_genius_config, nil
      set :active_session, nil
      set :host_authorization, permitted_hosts: []
      set :boot_token, nil
      set :current_profile_name, nil
      set :stats_history, nil
      set :stats_collector, nil

      CAPABILITIES = [:ai].freeze

      before do
        pass if request.get? && ["/", "/connections"].include?(request.path_info)
        unless request.cookies["mg_session"] == settings.boot_token
          content_type(:json)
          halt(403, { error: "Forbidden" }.to_json)
        end
      end

      after do
        if request.get? && ["/", "/connections"].include?(request.path_info)
          response.set_cookie(
            "mg_session",
            value:     settings.boot_token,
            httponly:  true,
            same_site: :strict,
            path:      "/",
          )
        end
      end

      helpers do
        def path_for(name)
          base = MysqlGenius::Desktop::PATHS.fetch(name)
          digest_routes = [:query_detail, :query_history]
          if digest_routes.include?(name) && @digest
            base + @digest.to_s
          else
            base
          end
        end

        def render_partial(name)
          Tilt.new(File.join(settings.views, "_#{name}.html.erb")).render(self)
        end

        def capability?(name)
          CAPABILITIES.include?(name)
        end
      end

      get "/" do
        tables = settings.active_session.checkout do |adapter|
          adapter.tables - settings.mysql_genius_config.security.blocked_tables
        end

        @all_tables              = tables.sort
        @featured_tables         = @all_tables
        @ai_enabled              = settings.mysql_genius_config.ai.enabled?
        @framework_version_major = MysqlGenius::Core::VERSION.split(".")[0]
        @framework_version_minor = MysqlGenius::Core::VERSION.split(".")[1]

        render_dashboard
      end

      post "/execute" do
        sql = params[:sql].to_s.strip
        row_limit = if params[:row_limit].to_s.empty?
          settings.mysql_genius_config.query.default_row_limit
        else
          params[:row_limit].to_i.clamp(1, settings.mysql_genius_config.query.max_row_limit)
        end

        runner_config = MysqlGenius::Core::QueryRunner::Config.new(
          blocked_tables:         settings.mysql_genius_config.security.blocked_tables,
          masked_column_patterns: settings.mysql_genius_config.security.masked_column_patterns,
          query_timeout_ms:       settings.mysql_genius_config.query.query_timeout_ms,
        )

        begin
          result = settings.active_session.checkout do |adapter|
            MysqlGenius::Core::QueryRunner.new(adapter, runner_config).run(sql, row_limit: row_limit)
          end
        rescue MysqlGenius::Core::QueryRunner::Rejected => e
          halt(422, json_response(error: e.message))
        rescue MysqlGenius::Core::QueryRunner::Timeout
          timeout_seconds = settings.mysql_genius_config.query.timeout_seconds
          halt(422, json_response(error: "Query exceeded the #{timeout_seconds} second timeout limit.", timeout: true))
        rescue StandardError => e
          halt(422, json_response(error: "Query error: #{e.message}"))
        end

        json_response(
          columns:           result.columns,
          rows:              result.rows,
          row_count:         result.row_count,
          execution_time_ms: result.execution_time_ms,
          truncated:         result.truncated,
        )
      end

      post "/explain" do
        sql = params[:sql].to_s.strip
        skip_validation = params[:from_slow_query].to_s == "true"

        runner_config = MysqlGenius::Core::QueryRunner::Config.new(
          blocked_tables:         settings.mysql_genius_config.security.blocked_tables,
          masked_column_patterns: settings.mysql_genius_config.security.masked_column_patterns,
          query_timeout_ms:       settings.mysql_genius_config.query.query_timeout_ms,
        )

        begin
          result = settings.active_session.checkout do |adapter|
            MysqlGenius::Core::QueryExplainer.new(adapter, runner_config).explain(sql, skip_validation: skip_validation)
          end
        rescue MysqlGenius::Core::QueryRunner::Rejected, MysqlGenius::Core::QueryExplainer::Truncated => e
          halt(422, json_response(error: e.message))
        rescue StandardError => e
          halt(422, json_response(error: "Explain error: #{e.message}"))
        end

        json_response(columns: result.columns, rows: result.rows)
      end

      get "/columns" do
        result = settings.active_session.checkout do |adapter|
          MysqlGenius::Core::Analysis::Columns.new(
            adapter,
            blocked_tables:         settings.mysql_genius_config.security.blocked_tables,
            masked_column_patterns: settings.mysql_genius_config.security.masked_column_patterns,
            default_columns:        settings.mysql_genius_config.security.default_columns,
          ).call(table: params[:table])
        end

        case result.status
        when :ok      then json_response(result.columns)
        when :blocked then halt(403, json_response(error: result.error_message))
        when :not_found then halt(404, json_response(error: result.error_message))
        end
      end

      get "/duplicate_indexes" do
        duplicates = settings.active_session.checkout do |adapter|
          MysqlGenius::Core::Analysis::DuplicateIndexes.new(
            adapter,
            blocked_tables: settings.mysql_genius_config.security.blocked_tables,
          ).call
        end
        json_response(duplicates)
      end

      get "/table_sizes" do
        tables = settings.active_session.checkout do |adapter|
          MysqlGenius::Core::Analysis::TableSizes.new(adapter).call
        end
        json_response(tables)
      end

      get "/query_stats" do
        sort  = params[:sort].to_s
        limit = params.fetch(:limit) { MysqlGenius::Core::Analysis::QueryStats::MAX_LIMIT }.to_i

        begin
          queries = settings.active_session.checkout do |adapter|
            MysqlGenius::Core::Analysis::QueryStats.new(adapter).call(sort: sort, limit: limit)
          end
        rescue StandardError => e
          halt(422, json_response(error: "Query statistics require performance_schema to be enabled. #{e.message}"))
        end

        json_response(queries)
      end

      get "/unused_indexes" do
        begin
          indexes = settings.active_session.checkout do |adapter|
            MysqlGenius::Core::Analysis::UnusedIndexes.new(adapter).call
          end
        rescue StandardError => e
          halt(422, json_response(error: "Unused index detection requires performance_schema. #{e.message}"))
        end

        json_response(indexes)
      end

      get "/server_overview" do
        begin
          overview = settings.active_session.checkout do |adapter|
            MysqlGenius::Core::Analysis::ServerOverview.new(adapter).call
          end
        rescue StandardError => e
          halt(422, json_response(error: "Failed to load server overview: #{e.message}"))
        end

        json_response(overview)
      end

      post "/suggest" do
        ai_not_configured unless settings.mysql_genius_config.ai.enabled?

        prompt = params[:prompt].to_s.strip
        halt(422, json_response(error: "Please describe what you want to query.")) if prompt.empty?

        begin
          result = settings.active_session.checkout do |adapter|
            core_config = build_ai_core_config
            MysqlGenius::Core::Ai::Suggestion.new(adapter, MysqlGenius::Core::Ai::Client.new(core_config), core_config)
              .call(prompt, queryable_tables(adapter))
          end
        rescue StandardError => e
          halt(422, json_response(error: "AI suggestion failed: #{e.message}"))
        end

        sql = result["sql"].to_s.gsub(/```(?:sql)?\s*/i, "").gsub("```", "").strip
        json_response(sql: sql, explanation: result["explanation"])
      end

      post "/optimize" do
        ai_not_configured unless settings.mysql_genius_config.ai.enabled?

        sql = params[:sql].to_s.strip
        explain_rows = coerce_explain_rows(params[:explain_rows])
        halt(422, json_response(error: "SQL and EXPLAIN output are required.")) if sql.empty? || explain_rows.empty?

        begin
          result = settings.active_session.checkout do |adapter|
            core_config = build_ai_core_config
            MysqlGenius::Core::Ai::Optimization.new(adapter, MysqlGenius::Core::Ai::Client.new(core_config), core_config)
              .call(sql, explain_rows, queryable_tables(adapter))
          end
        rescue StandardError => e
          halt(422, json_response(error: "Optimization failed: #{e.message}"))
        end

        json_response(result)
      end

      post "/describe_query" do
        ai_not_configured unless settings.mysql_genius_config.ai.enabled?

        sql = params[:sql].to_s.strip
        halt(422, json_response(error: "SQL is required.")) if sql.empty?

        begin
          core_config = build_ai_core_config
          result = MysqlGenius::Core::Ai::DescribeQuery.new(MysqlGenius::Core::Ai::Client.new(core_config), core_config).call(sql)
        rescue StandardError => e
          halt(422, json_response(error: "Explanation failed: #{e.message}"))
        end

        json_response(result)
      end

      post "/schema_review" do
        ai_not_configured unless settings.mysql_genius_config.ai.enabled?

        table = params[:table].to_s.strip.empty? ? nil : params[:table].to_s.strip

        begin
          result = settings.active_session.checkout do |adapter|
            core_config = build_ai_core_config
            MysqlGenius::Core::Ai::SchemaReview.new(MysqlGenius::Core::Ai::Client.new(core_config), core_config, adapter).call(table)
          end
        rescue StandardError => e
          halt(422, json_response(error: "Schema review failed: #{e.message}"))
        end

        json_response(result)
      end

      post "/rewrite_query" do
        ai_not_configured unless settings.mysql_genius_config.ai.enabled?

        sql = params[:sql].to_s.strip
        halt(422, json_response(error: "SQL is required.")) if sql.empty?

        begin
          result = settings.active_session.checkout do |adapter|
            core_config = build_ai_core_config
            MysqlGenius::Core::Ai::RewriteQuery.new(MysqlGenius::Core::Ai::Client.new(core_config), core_config, adapter).call(sql)
          end
        rescue StandardError => e
          halt(422, json_response(error: "Rewrite failed: #{e.message}"))
        end

        json_response(result)
      end

      post "/index_advisor" do
        ai_not_configured unless settings.mysql_genius_config.ai.enabled?

        sql = params[:sql].to_s.strip
        explain_rows = coerce_explain_rows(params[:explain_rows])
        halt(422, json_response(error: "SQL and EXPLAIN output are required.")) if sql.empty? || explain_rows.empty?

        begin
          result = settings.active_session.checkout do |adapter|
            core_config = build_ai_core_config
            MysqlGenius::Core::Ai::IndexAdvisor.new(MysqlGenius::Core::Ai::Client.new(core_config), core_config, adapter).call(sql, explain_rows)
          end
        rescue StandardError => e
          halt(422, json_response(error: "Index advisor failed: #{e.message}"))
        end

        json_response(result)
      end

      post "/migration_risk" do
        ai_not_configured unless settings.mysql_genius_config.ai.enabled?

        migration_sql = params[:migration].to_s.strip
        halt(422, json_response(error: "Migration SQL or Ruby code is required.")) if migration_sql.empty?

        begin
          result = settings.active_session.checkout do |adapter|
            core_config = build_ai_core_config
            MysqlGenius::Core::Ai::MigrationRisk.new(MysqlGenius::Core::Ai::Client.new(core_config), core_config, adapter).call(migration_sql)
          end
        rescue StandardError => e
          halt(422, json_response(error: "Migration risk assessment failed: #{e.message}"))
        end

        json_response(result)
      end

      # --- Profile API ---

      get "/api/profiles" do
        manager = ProfileManager.new(settings.mysql_genius_config.source_path)
        json_response(profiles: manager.list, current: settings.current_profile_name)
      end

      post "/api/profiles" do
        data = JSON.parse(request.body.read)
        manager = ProfileManager.new(settings.mysql_genius_config.source_path)
        manager.add(name: data["name"], mysql: data["mysql"])
        json_response(profiles: manager.list)
      rescue ProfileManager::DuplicateProfileError => e
        halt(409, json_response(error: e.message))
      end

      put "/api/profiles/:name" do
        data = JSON.parse(request.body.read)
        manager = ProfileManager.new(settings.mysql_genius_config.source_path)
        manager.update(name: params[:name], mysql: data["mysql"])
        json_response(profiles: manager.list)
      rescue ProfileManager::ProfileNotFoundError => e
        halt(404, json_response(error: e.message))
      end

      delete "/api/profiles/:name" do
        manager = ProfileManager.new(settings.mysql_genius_config.source_path)
        manager.delete(name: params[:name], current_profile: settings.current_profile_name)
        json_response(profiles: manager.list)
      rescue ProfileManager::ProfileNotFoundError => e
        halt(404, json_response(error: e.message))
      rescue ProfileManager::ActiveProfileError => e
        halt(422, json_response(error: e.message))
      end

      post "/api/test_connection" do
        data = JSON.parse(request.body.read)
        mysql = data["mysql"]
        halt(422, json_response(error: "mysql config is required")) unless mysql

        manager = ProfileManager.new(settings.mysql_genius_config.source_path)
        result = manager.test_connection(mysql: mysql)
        json_response(result)
      end

      post "/api/profiles/:name/connect" do
        swapper = SessionSwapper.new(self.class, settings.mysql_genius_config)
        swapper.switch_to(params[:name])
        json_response(success: true, profile: params[:name])
      rescue ActiveSession::ConnectError => e
        halt(422, json_response(error: e.message))
      end

      get "/queries/:digest" do
        @digest = params[:digest].to_s
        render_query_detail
      end

      get "/api/query_history/:digest" do
        digest = params[:digest].to_s
        current_query = fetch_query_history_current(digest)
        history = fetch_query_history_series(digest)
        json_response(query: current_query, history: history)
      rescue StandardError => e
        halt(422, json_response(error: e.message))
      end

      get "/connections" do
        render_connections
      end

      get "/api/ai_config" do
        manager = ProfileManager.new(settings.mysql_genius_config.source_path)
        json_response(manager.read_ai_config)
      end

      put "/api/ai_config" do
        data = JSON.parse(request.body.read)
        manager = ProfileManager.new(settings.mysql_genius_config.source_path)
        manager.update_ai_config(data)

        # Reload the AI config into the running app
        ai = Config::AiConfig.from_hash(data)
        settings.mysql_genius_config.instance_variable_set(:@ai, ai)

        json_response(manager.read_ai_config)
      rescue StandardError => e
        halt(422, json_response(error: e.message))
      end

      private

      LAYOUT_PATH = File.expand_path("layout.html.erb", __dir__).freeze

      def render_connections
        connections_path = File.expand_path("connections.html.erb", __dir__)
        content = Tilt.new(connections_path).render(self)
        Tilt.new(LAYOUT_PATH).render(self) { content }
      end

      def render_dashboard
        dashboard_path = File.join(MysqlGenius::Core.views_path, "mysql_genius/queries/dashboard.html.erb")
        content = Tilt.new(dashboard_path).render(self)
        Tilt.new(LAYOUT_PATH).render(self) { content }
      end

      def render_query_detail
        detail_path = File.join(MysqlGenius::Core.views_path, "mysql_genius/queries/query_detail.html.erb")
        content = Tilt.new(detail_path).render(self)
        Tilt.new(LAYOUT_PATH).render(self) { content }
      end

      def fetch_query_history_current(digest)
        settings.active_session.checkout do |adapter|
          sql = "SELECT DIGEST_TEXT, COUNT_STAR AS calls, " \
            "ROUND(SUM_TIMER_WAIT / 1000000000.0, 2) AS total_time_ms, " \
            "ROUND(AVG_TIMER_WAIT / 1000000000.0, 2) AS avg_time_ms, " \
            "ROUND(MAX_TIMER_WAIT / 1000000000.0, 2) AS max_time_ms, " \
            "SUM_ROWS_EXAMINED AS rows_examined, " \
            "SUM_ROWS_SENT AS rows_sent, " \
            "FIRST_SEEN, LAST_SEEN " \
            "FROM performance_schema.events_statements_summary_by_digest " \
            "WHERE DIGEST = '#{digest.gsub("'", "''")}' LIMIT 1"
          result = adapter.exec_query(sql)
          return nil if result.rows.empty?

          row = result.to_hashes.first
          {
            sql: row["DIGEST_TEXT"],
            calls: row["calls"],
            total_time_ms: row["total_time_ms"].to_f,
            avg_time_ms: row["avg_time_ms"].to_f,
            max_time_ms: row["max_time_ms"].to_f,
            rows_examined: row["rows_examined"],
            rows_sent: row["rows_sent"],
            first_seen: row["FIRST_SEEN"].to_s,
            last_seen: row["LAST_SEEN"].to_s,
          }
        end
      end

      def fetch_query_history_series(digest)
        return [] unless settings.stats_history

        digest_text = settings.active_session.checkout do |adapter|
          sql = "SELECT DIGEST_TEXT FROM performance_schema.events_statements_summary_by_digest " \
            "WHERE DIGEST = '#{digest.gsub("'", "''")}' LIMIT 1"
          result = adapter.exec_query(sql)
          result.rows.empty? ? nil : result.to_hashes.first["DIGEST_TEXT"]
        end

        return [] unless digest_text

        settings.stats_history.series_for(digest_text)
      end

      def json_response(obj)
        content_type(:json)
        obj.to_json
      end

      def ai_not_configured
        halt(404, json_response(error: "AI features are not configured."))
      end

      def build_ai_core_config
        ai = settings.mysql_genius_config.ai
        MysqlGenius::Core::Ai::Config.new(
          client:         nil,
          endpoint:       ai.endpoint,
          api_key:        ai.api_key,
          model:          ai.model,
          auth_style:     ai.auth_style,
          system_context: ai.system_context,
          domain_context: ai.domain_context,
        )
      end

      def queryable_tables(adapter)
        adapter.tables - settings.mysql_genius_config.security.blocked_tables
      end

      def coerce_explain_rows(raw)
        return [] if raw.nil?

        Array(raw).map { |row| row.respond_to?(:values) ? row.values : Array(row) }
      end
    end
  end
end
