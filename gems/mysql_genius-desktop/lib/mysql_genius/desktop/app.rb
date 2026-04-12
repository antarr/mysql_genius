# frozen_string_literal: true

require "sinatra/base"
require "tilt"
require "json"
require "mysql_genius/core"
require "mysql_genius/desktop/paths"

module MysqlGenius
  module Desktop
    class App < Sinatra::Base
      set :views, File.join(MysqlGenius::Core.views_path, "mysql_genius/queries")
      set :server, "puma"
      set :quiet, true
      set :mysql_genius_config, nil
      set :active_session, nil
      set :host_authorization, permitted_hosts: []

      CAPABILITIES = [:ai].freeze

      helpers do
        def path_for(name)
          MysqlGenius::Desktop::PATHS.fetch(name)
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

      private

      def render_dashboard
        path = File.join(MysqlGenius::Core.views_path, "mysql_genius/queries/dashboard.html.erb")
        Tilt.new(path).render(self)
      end

      def json_response(obj)
        content_type(:json)
        obj.to_json
      end
    end
  end
end
