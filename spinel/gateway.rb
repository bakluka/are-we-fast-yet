require_relative "lib/gateway"

ROUTES = Gateway.routes do
  route "/api", to: [9001, 9002] do
    rate_limit per_second: 1_000_000, plans: { "free" => 1_000 }
    rewrite redact: %w[email]
  end

  route "/static", to: [9003, 9004] do
    cache ttl: 1
  end

  route "/", to: [9003, 9004]
end

ENV["SPINEL_WORKERS"] = ENV["WORKERS"] if ENV["WORKERS"]
Gateway.start(ROUTES)
