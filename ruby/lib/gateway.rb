# shareable_constant_value: literal

require "async"
require "etc"
require "json"
require "ratomic"
require "socket"
require "tmpdir"

require_relative "gateway/http"
require_relative "gateway/tally"
require_relative "gateway/keeper"
require_relative "gateway/upstream"
require_relative "gateway/rate_limit"
require_relative "gateway/cache"
require_relative "gateway/rewrite"
require_relative "gateway/metrics"
require_relative "gateway/app"
require_relative "gateway/routes"
require_relative "gateway/server"

Warning[:experimental] = false
Async::Scheduler.undef_method(:io_read, :io_write)

module Gateway
  METRICS = Metrics.new

  def self.routes(&) = Routes.draw(&)

  def self.start(routes, port: 8080, workers: Etc.nprocessors, mode: "ractor")
    case mode
    in "ractor"
      collect_shareable_garbage
      workers.times.map { Ractor.new(routes, port) { |routes, port| Gateway.serve(routes, port) } }.each(&:join)
    in "thread"
      workers.times.map { Thread.new { serve(routes, port) } }.each(&:join)
    in "fork"
      keeper = Keeper.new
      workers.times { fork { serve_kept(routes, port, keeper.link) } }
      keeper.run
    in "fork-unsynced"
      workers.times.map { fork { serve(routes, port) } }.each { Process.wait(it) }
    end
  end

  def self.serve(routes, port, metrics: METRICS) = Server.new(App.new(routes, metrics:), port:).run

  def self.serve_kept(routes, port, link)
    serve(routes.map { it.kept_by(link) }, port, metrics: METRICS.kept_by(link))
  end

  def self.collect_shareable_garbage(every: 1) = Thread.new { loop { sleep every; GC.start } }
end
