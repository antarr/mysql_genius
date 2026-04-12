# frozen_string_literal: true

module MysqlGenius
  module SharedViewHelpers
    extend ActiveSupport::Concern

    included do
      helper_method :path_for, :render_partial, :capability?
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

    # Capability flag for shared templates. The Rails adapter always
    # reports every capability as present because it owns all routes
    # (including the Redis-backed slow_queries / anomaly_detection /
    # root_cause features). The Phase 2b sidecar overrides this with a
    # narrower list in its own Sinatra app, which is why shared templates
    # gate the associated UI via `<% if capability?(:slow_queries) %>` etc.
    def capability?(_name)
      true
    end
  end
end
