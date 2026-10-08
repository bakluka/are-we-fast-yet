require "json"
require "socket"

require_relative "gateway/shared"
require_relative "gateway/http"
require_relative "gateway/upstream"
require_relative "gateway/rate_limit"
require_relative "gateway/cache"
require_relative "gateway/rewrite"
require_relative "gateway/metrics"
require_relative "gateway/app"
require_relative "gateway/routes"
require_relative "gateway/server"

module Gateway
  METRICS = Metrics.new

  def self.routes(&) = Routes.draw(&)
  def self.start(routes, port: 8080) = Server.new(App.new(routes), port:).run
end
