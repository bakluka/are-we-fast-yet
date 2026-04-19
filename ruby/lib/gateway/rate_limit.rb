module Gateway
  RateLimit = Data.define(:per_second, :plans, :windows) do
    def initialize(per_second:, plans: {}, windows: Tally.new) = super

    def kept_by(link, name) = with(windows: link.tally(name))

    def call(request)
      client = request.headers["x-api-key"] || request.client
      limit = plans.fetch(client, per_second)
      used = count(client)
      return HTTP::Response.text(429).with_headers("retry-after" => "1") if used > limit

      yield(request).with_headers("x-ratelimit-limit" => limit.to_s, "x-ratelimit-remaining" => (limit - used).to_s)
    end

    private

    def count(client)
      second = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
      windows.add(-"#{client}@#{second}").tap { windows.delete(-"#{client}@#{second - 2}") if it == 1 }
    end
  end
end
