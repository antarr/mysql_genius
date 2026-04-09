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
  end
end
