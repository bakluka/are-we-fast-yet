require_relative "../../ruby/lib/gateway"

include Gateway::HTTP

document = File.read(File.join(__dir__, "doc.json"))
response = Response.new(status: 200, reason: "OK", body: document, headers: Headers.new("content-type" => "application/json"))
rewrite = Gateway::Rewrite.new(redact: %w[email])

{ "4 fields" => "fields=id,name,email,created_at", "whole document" => nil }.each do |label, query|
  request = Request.new(verb: "GET", path: "/api/users", query:, headers: Headers.new, body: "", client: "127.0.0.1")
  run = proc { rewrite.call(request) { response } }
  2_000.times(&run)
  best = 5.times.map do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    5_000.times(&run)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 5_000 * 1e6
  end.min
  puts format("%-8s %-15s %.1f us/op", RUBY_DESCRIPTION[/\+(YJIT|ZJIT)/, 1] || "interp", label, best)
end
