# shareable_constant_value: experimental_everything

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

Gateway.start(
  ROUTES,
  workers: Integer(ENV.fetch("WORKERS", Etc.nprocessors)),
  mode: ENV.fetch("MODE", "ractor")
)
