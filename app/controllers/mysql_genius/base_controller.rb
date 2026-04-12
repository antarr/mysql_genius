# frozen_string_literal: true

module MysqlGenius
  class BaseController < MysqlGenius.configuration.base_controller.constantize
    layout "mysql_genius/application"
    before_action :authenticate_mysql_genius!

    private

    def authenticate_mysql_genius!
      unless MysqlGenius.configuration.authenticate.call(self)
        render(plain: "Not authorized", status: :unauthorized)
      end
    end

    def mysql_genius_config
      MysqlGenius.configuration
    end

    # Wraps ActiveRecord::Base.connection in a Core::Connection::ActiveRecordAdapter.
    # Every controller action that delegates to a Core::* service calls this
    # instead of instantiating the adapter inline. Shared across all concerns
    # (QueryExecution, DatabaseAnalysis, AiFeatures) via BaseController's
    # private method lookup.
    def rails_connection
      MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
    end
  end
end
