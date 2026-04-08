module MysqlGenius
  class BaseController < ActionController::Base
    before_action :authenticate_mysql_genius!

    private

    def authenticate_mysql_genius!
      unless MysqlGenius.configuration.authenticate.call(self)
        render plain: "Not authorized", status: :unauthorized
      end
    end

    def config
      MysqlGenius.configuration
    end
  end
end
