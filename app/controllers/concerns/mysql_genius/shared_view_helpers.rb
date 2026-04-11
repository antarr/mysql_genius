# frozen_string_literal: true

module MysqlGenius
  module SharedViewHelpers
    extend ActiveSupport::Concern

    included do
      helper_method :path_for, :render_partial
    end

    # URL path helper for shared templates.
    #   path_for(:execute) # => "/mysql_genius/execute" (from engine route helpers)
    def path_for(name)
      mysql_genius.public_send("#{name}_path")
    end

    # Partial renderer for shared templates.
    #   render_partial(:tab_dashboard) # => view_context.render partial: "mysql_genius/queries/tab_dashboard"
    def render_partial(name)
      view_context.render(partial: "mysql_genius/queries/#{name}")
    end
  end
end
