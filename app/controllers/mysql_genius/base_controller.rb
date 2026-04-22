# frozen_string_literal: true

module MysqlGenius
  class BaseController < MysqlGenius.configuration.base_controller.constantize
    layout "mysql_genius/application"
    before_action :authenticate_mysql_genius!
    before_action :set_current_database, unless: :setup_action?

    private

    def authenticate_mysql_genius!
      unless MysqlGenius.configuration.authenticate.call(self)
        render(plain: "Not authorized", status: :unauthorized)
      end
    end

    def mysql_genius_config
      MysqlGenius.configuration
    end

    # Resolves the current MysqlGenius::Database from params[:database_id].
    # The route scope guarantees database_id is always present on every action
    # except #setup (which is gated by setup_action? above).
    #
    # When the registry is empty (no MySQL connection in config/database.yml)
    # we redirect to the setup page rather than 404-ing — users hitting a
    # nested URL with no configured DB are almost certainly first-time users.
    def set_current_database
      if MysqlGenius.database_registry.empty?
        redirect_to(setup_path) && return
      end

      key = params[:database_id].to_s
      @database = MysqlGenius.database_registry[key]
      return if @database

      raise(ActionController::RoutingError, "Unknown mysql_genius database: #{key.inspect}")
    end

    def setup_action?
      action_name == "setup"
    end

    # Wraps the current database's AR connection in a Core::Connection::ActiveRecordAdapter.
    # Every controller action that delegates to a Core::* service calls this
    # instead of instantiating the adapter inline. Shared across all concerns
    # (QueryExecution, DatabaseAnalysis, AiFeatures) via BaseController's
    # private method lookup.
    def rails_connection
      MysqlGenius::Core::Connection::ActiveRecordAdapter.new(active_record_connection)
    end

    # Raw ActiveRecord connection for the current database. Used by controller
    # callsites (query_history, a couple of AI features) that need methods
    # like #quote and #current_database directly, not through the Core adapter.
    def active_record_connection
      @database.ar_connection
    end
  end
end
