# shareable_constant_value: literal

module Gateway
  Upstream = Data.define(:port, :inflight) do
    def initialize(port:, inflight: Ratomic::Counter.new) = super

    def load = inflight.read
  end

  class Balancer
    def initialize(upstreams)
      @pools = upstreams.map { Pool.new(it) }
    end

    def call(request) = @pools.min_by(&:load).call(request)
  end

  class Pool
    VIA = "1.1 gateway"

    def initialize(upstream)
      @upstream = upstream
      @idle = []
    end

    def load = @upstream.load

    def call(request)
      @upstream.inflight.increment(1)
      response = checkout { |stream| exchange(stream, forwarded(request)) }
      response.with(headers: response.headers.end_to_end.merge("via" => VIA))
    rescue SystemCallError, IOError
      HTTP::Response.text(502)
    ensure
      @upstream.inflight.decrement(1)
    end

    private

    def forwarded(request)
      request.with(headers: request.headers.end_to_end.merge("x-forwarded-for" => request.client, "via" => VIA))
    end

    def exchange(stream, request)
      stream.write(request)
      stream.read_response
    end

    def checkout
      stream = @idle.pop || connect
      yield(stream).tap { @idle.push(stream) }
    rescue
      stream&.close
      raise
    end

    def connect
      socket = Socket.tcp("127.0.0.1", @upstream.port)
      socket.setsockopt(:TCP, :NODELAY, true)
      HTTP::Stream.new(socket)
    end
  end
end
