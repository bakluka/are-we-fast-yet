module Gateway
  class Routes
    def self.draw(&) = new.tap { it.instance_eval(&) }.to_a

    def initialize
      @routes = []
    end

    def route(prefix, to:, &layers)
      @routes << Route.new(prefix:, upstreams: to.map { Upstream.new(port: it) }, layers: Layers.draw(&layers))
    end

    def to_a = @routes
  end

  class Layers
    def self.draw(&block) = new.tap { it.instance_eval(&block) if block }.to_a

    def initialize
      @layers = []
    end

    def rate_limit(**) = @layers << RateLimit.new(**)
    def rewrite(**) = @layers << Rewrite.new(**)
    def cache(**) = @layers << Cache.new(**)
    def to_a = @layers
  end
end
