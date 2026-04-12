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
