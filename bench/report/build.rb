require "erb"
require "json"
require "cgi"
require "time"

ROOT = File.expand_path("../..", __dir__)
load_results = ->(dir) { Dir[File.join(dir, "*.json")].to_h { [File.basename(it, ".json"), JSON.parse(File.read(it), symbolize_names: true)] } }
RESULTS = load_results.(File.join(ROOT, "bench/results"))
V1 = load_results.(File.join(ROOT, "bench/results/v1"))
NOTES = JSON.parse(File.read(File.join(__dir__, "notes.json")), symbolize_names: true)

def lookup(results, scenario, **match) = results.fetch(scenario).find { |run| match.all? { |key, value| run[key] == value } } || raise("no #{scenario} run for #{match}")
def find(scenario, **match) = lookup(RESULTS, scenario, **match)
def find_v1(scenario, **match) = lookup(V1, scenario, **match)
def rps(scenario, impl, workers, route) = find(scenario, impl:, workers:, route:)[:rps]
def rps_v1(scenario, impl, workers, route) = find_v1(scenario, impl:, workers:, route:)[:rps]
def kilo(n) = n >= 100_000 ? "#{(n / 1000.0).round}k" : "#{(n / 1000.0).round(1)}k"
def times(a, b) = "#{(a.to_f / b).round(a.to_f / b >= 10 ? 0 : 1)}×"
def pct(a, b) = "#{((a.to_f / b - 1) * 100).round}%"
def mb(kb) = "#{(kb / 1024.0).round} MB"
def ms_text(v) = v >= 1000 ? "#{(v / 1000.0).round(1)} s" : v >= 10 ? "#{v.round} ms" : "#{v.round(1)} ms"
def num(n) = n.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
def h(text) = CGI.escapeHTML(text.to_s)
def lines(path) = File.readlines(File.join(ROOT, path)).count { it.strip != "" }

def lead(a_name, a, b_name, b)
  gap = a.to_f / b - 1
  return "#{a_name} and #{b_name} are level" if gap.abs < 0.03
  gap.positive? ? "#{a_name} is #{(gap * 100).round}% ahead" : "#{b_name} is #{(-gap * 100).round}% ahead"
end

SOURCES = %w[gateway.rb lib/gateway.rb lib/gateway/routes.rb lib/gateway/app.rb lib/gateway/http.rb lib/gateway/upstream.rb lib/gateway/rate_limit.rb lib/gateway/cache.rb lib/gateway/rewrite.rb lib/gateway/metrics.rb lib/gateway/server.rb bin/gateway]
  .to_h { [it, File.read(File.join(ROOT, "ruby", it))] }

data = RESULTS.merge(v1: V1.slice("scaling"), notes: NOTES)
DATA_JSON = JSON.generate(data).gsub("</", "<\\/")
html = ERB.new(File.read(File.join(__dir__, "template.html.erb")), trim_mode: "-").result(binding)
File.write(File.join(__dir__, "index.html"), html)
puts "wrote #{File.join(__dir__, "index.html")} (#{html.bytesize} bytes)"
