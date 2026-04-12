# frozen_string_literal: true

module MysqlGenius
  module Desktop
    class Config
      class ServerConfig < Struct.new(:port, :bind, keyword_init: true)
        DEFAULTS = { port: 4567, bind: "127.0.0.1" }.freeze

        class << self
          def from_hash(hash, override_port: nil, override_bind: nil)
            hash = hash.transform_keys(&:to_sym)
            merged = DEFAULTS.merge(hash)
            merged[:port] = override_port if override_port
            merged[:bind] = override_bind if override_bind
            new(**merged)
          end
        end
      end
    end
  end
end
