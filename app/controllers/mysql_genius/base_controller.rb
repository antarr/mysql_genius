# frozen_string_literal: true

module MysqlGenius
  class BaseController < MysqlGenius.configuration.base_controller.constantize
    layout "mysql_genius/application"
    before_action :authenticate_mysql_genius!
    before_action :resolve_database!

    helper_method :current_database_key, :current_database_config, :multi_db?, :available_databases

    private

    def authenticate_mysql_genius!
      unless MysqlGenius.configuration.authenticate.call(self)
        render(plain: "Not authorized", status: :unauthorized)
      end
    end

    def resolve_database!
      databases = MysqlGenius.databases
      registry = MysqlGenius::DatabaseRegistry

      if params[:database].present?
        key = params[:database].to_sym
        unless databases.key?(key)
          render(plain: "Database not found", status: :not_found)
          return
        end
        @current_database_key = key
      elsif registry.multi_db?(mysql_genius_config)
        redirect_to(mysql_genius.root_path(database: registry.default_key(mysql_genius_config)))
        return
      else
        @current_database_key = registry.default_key(mysql_genius_config)
      end

      @current_database_config = databases[@current_database_key] || mysql_genius_config.database(@current_database_key)
    end

    attr_reader :current_database_key

    attr_reader :current_database_config

    def connection
      @connection ||= resolve_connection
    end

    def multi_db?
      MysqlGenius::DatabaseRegistry.multi_db?(mysql_genius_config)
    end

    def available_databases
      MysqlGenius.databases
    end

    def mysql_genius_config
      MysqlGenius.configuration
    end

    def resolve_connection
      spec = @current_database_config&.connection_spec
      if spec && defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:connected_to)
        pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(spec)
        pool ? pool.connection : ActiveRecord::Base.connection
      else
        ActiveRecord::Base.connection
      end
    end
  end
end
