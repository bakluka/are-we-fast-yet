module Gateway
  RateLimit = Data.define(:per_second, :plans, :windows) do
    def initialize(per_second:, plans: {}, windows: SharedMap.new) = super

    def call(request)
      client = request.headers["x-api-key"] || request.client
      limit = plans.fetch(client, per_second)
      used = window(client).increment(1)
      return HTTP::Response.text(429).with_header("retry-after", "1") if used > limit

      yield(request)
        .with_header("x-ratelimit-limit", limit.to_s)
        .with_header("x-ratelimit-remaining", (limit - used).to_s)
    end

    private

    def window(client)
      second = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
      windows["#{client}@#{second}"] ||= begin
        windows.delete("#{client}@#{second - 2}")
        Counter.new
      end
    end
  end
end
