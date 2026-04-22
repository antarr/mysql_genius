# frozen_string_literal: true

module MysqlGenius
  module SharedViewHelpers
    extend ActiveSupport::Concern

    included do
      helper_method :path_for, :render_partial, :capability?
    end

    # URL path helper for shared templates.
    #   path_for(:execute) # => "/mysql_genius/primary/execute" (from engine route helpers)
    #
    # All dashboard routes are nested under `:database_id`, so helpers resolve
    # to `database_<name>_path(database_id: @database.key)`. When @digest is
    # set (query detail page), routes that require a digest param
    # (query_detail, query_history) are generated with it automatically.
    def path_for(name)
      db_id = @database&.key
      digest_routes = [:query_detail, :query_history]
      args = { database_id: db_id }
      args[:digest] = @digest if digest_routes.include?(name) && @digest
      mysql_genius.public_send("database_#{name}_path", **args)
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
