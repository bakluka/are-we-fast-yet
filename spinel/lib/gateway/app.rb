module Gateway
  Route = Data.define(:prefix, :upstreams, :layers) do
    def initialize(prefix:, upstreams:, layers: [])
      super(prefix:, upstreams: upstreams.map { Upstream.new(port: it) }, layers:)
    end

    def match?(request) = request.path.start_with?(prefix)
  end

  class App
    def initialize(routes, metrics: METRICS)
      @endpoints = routes.map { Endpoint.new(it) }
      @metrics = metrics
    end

    def call(request) = @metrics.call(request) { route(it) }

    private

    def route(request)
      endpoint = @endpoints.find { it.match?(request) }
      endpoint ? endpoint.call(request) : HTTP::Response.text(404)
    end
  end

  class Endpoint
    def initialize(route)
      @route = route
      @balancer = Balancer.new(route.upstreams)
    end

    def match?(request) = @route.match?(request)

    def call(request, layers = @route.layers)
      layer, *rest = layers
      return @balancer.call(request) unless layer

      layer.call(request) { call(it, rest) }
    end
  end
end
