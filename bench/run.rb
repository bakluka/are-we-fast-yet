require "fileutils"
require "json"
require "socket"
require "timeout"

ROOT = File.expand_path("..", __dir__)
OUT = File.join(ROOT, "bench/results")
VARIANTS = File.join(ROOT, "bench/.variants")
WRK2 = File.expand_path("~/.local/bin/wrk2")
RUBIES = { "master" => "~/.rbenv/versions/4.1.0-dev/bin", "4.0.6" => "~/.rbenv/versions/4.0.6/bin" }.transform_values { File.expand_path(it) }
CORES = { 1 => "0", 2 => "0-1", 4 => "0-3", 8 => "0-3,8-11" }
UPSTREAM_CPUS = "4,5,12,13"
WRK_CPUS = "6,7,14,15"
PORT = 8080
TICK = Integer(`getconf CLK_TCK`)
BENCH_KEY = ["-H", "X-Api-Key: bench"]

ROUTES = {
  "raw" => { path: "/raw/x" },
  "api" => { path: "/api/users?fields=id,name,email,created_at", headers: BENCH_KEY },
  "hit" => { path: "/static/logo.png" },
  "slow" => { path: "/raw/x?delay=50" },
  "free" => { path: "/api/users?fields=id", headers: ["-H", "X-Api-Key: free"] },
  "catalog" => { path: "/", script: File.join(ROOT, "bench/scripts/catalog.lua") },
  "catalog-big" => { path: "/?kb=64", script: File.join(ROOT, "bench/scripts/catalog.lua") },
}

HEAP = { "RUBY_GC_RACTOR_HEAP_INIT_BYTES" => "2621440" }
STOCK = { "RUBY_GC_RACTOR_HEAP_INIT_BYTES" => nil }

FileUtils.mkdir_p([OUT, VARIANTS])
HOOKED = File.join(VARIANTS, "hooked")
FileUtils.rm_rf(HOOKED)
FileUtils.cp_r(File.join(ROOT, "ruby"), HOOKED)
File.write(File.join(HOOKED, "lib/gateway.rb"), File.read(File.join(HOOKED, "lib/gateway.rb")).sub(/^Async::Scheduler\.undef_method.*\n/, "").sub(/^\s*collect_shareable_garbage\n/, ""))
LEAKY = File.join(VARIANTS, "leaky")
FileUtils.rm_rf(LEAKY)
FileUtils.cp_r(File.join(ROOT, "ruby"), LEAKY)
File.write(File.join(LEAKY, "lib/gateway.rb"), File.read(File.join(LEAKY, "lib/gateway.rb")).sub(/^\s*collect_shareable_garbage\n/, ""))

IMPLS = {
  "go-std" => { argv: %w[go/bin/gateway-std] },
  "go-jsontext" => { argv: %w[go/bin/gateway-jsontext] },
  "ruby-ractor" => { argv: %w[ruby/bin/gateway], env: { "MODE" => "ractor" } },
  "ruby-fork" => { argv: %w[ruby/bin/gateway], env: { "MODE" => "fork" } },
  "ruby-fork-unsynced" => { argv: %w[ruby/bin/gateway], env: { "MODE" => "fork-unsynced" } },
  "ruby-thread" => { argv: %w[ruby/bin/gateway], env: { "MODE" => "thread" } },
  "ruby406-ractor" => { argv: %w[ruby/bin/gateway], env: { "MODE" => "ractor" }, ruby: "4.0.6" },
  "ruby406-fork" => { argv: %w[ruby/bin/gateway], env: { "MODE" => "fork-unsynced" }, ruby: "4.0.6" },
  "ruby-stock" => { argv: ["ruby", "--yjit", File.join(HOOKED, "gateway.rb")], env: { "MODE" => "ractor", **STOCK } },
  "ruby-heap" => { argv: ["ruby", "--yjit", File.join(HOOKED, "gateway.rb")], env: { "MODE" => "ractor", **HEAP } },
  "ruby-leaky" => { argv: [File.join(LEAKY, "bin/gateway")], env: { "MODE" => "ractor" } },
  "ruby-interp" => { argv: %w[ruby ruby/gateway.rb], env: { "MODE" => "ractor", **HEAP } },
  "ruby-zjit" => { argv: %w[ruby --zjit ruby/gateway.rb], env: { "MODE" => "ractor", **HEAP } },
  "spinel" => { argv: %w[spinel/bin/gateway] },
  "spinel-stock" => { argv: %w[spinel/build/gateway] },
}

ONLY = ENV["ONLY"]&.split(",")

def log(message) = $stderr.puts("[#{Time.now.strftime("%H:%M:%S")}] #{message}")
def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def wait_until(timeout = 30)
  deadline = clock + timeout
  sleep 0.05 until yield || clock > deadline
  yield or raise "timed out waiting"
end

def port_free? = listeners.zero?

def listeners
  %w[/proc/net/tcp /proc/net/tcp6].sum do |table|
    File.readlines(table).count { |line| line.split[1].end_with?(":%04X" % PORT) && line.split[3] == "0A" }
  end
end

def group(pgid)
  Dir["/proc/[0-9]*/stat"].filter_map do |path|
    fields = File.read(path).rpartition(") ").last.split
    path[/\d+/].to_i if fields[2].to_i == pgid
  rescue Errno::ENOENT, Errno::ESRCH
  end
end

def cpu_ticks(pgid)
  group(pgid).sum { |pid| File.read("/proc/#{pid}/stat").rpartition(") ").last.split.values_at(11, 12).sum(&:to_i) rescue 0 }
end

def memory_kb(pgid)
  group(pgid).each_with_object(rss: 0, pss: 0) do |pid, total|
    rollup = File.read("/proc/#{pid}/smaps_rollup")
    total[:rss] += rollup[/^Rss:\s+(\d+)/, 1].to_i
    total[:pss] += rollup[/^Pss:\s+(\d+)/, 1].to_i
  rescue Errno::ENOENT, Errno::ESRCH
  end
end

def to_ms(text)
  return unless text
  value = text.to_f
  case text
  when /us\z/ then value / 1000
  when /ms\z/ then value
  when /m\z/ then value * 60_000
  when /s\z/ then value * 1000
  else value
  end
end

def start(name, workers)
  impl = IMPLS.fetch(name)
  wait_until { port_free? }
  env = { "PATH" => "#{RUBIES.fetch(impl.fetch(:ruby, "master"))}:#{ENV["PATH"]}", "WORKERS" => workers.to_s, **impl.fetch(:env, {}) }
  argv = impl[:argv].map { it.include?("/") && !it.start_with?("/") ? File.join(ROOT, it) : it }
  logfile = File.open(File.join(VARIANTS, "#{name}.log"), "a")
  t0 = clock
  pid = Process.spawn(env, "taskset", "-c", CORES.fetch(workers), *argv, chdir: ROOT, pgroup: true, out: logfile, err: logfile)
  wait_until { listeners >= (name.start_with?("go", "spinel") ? 1 : workers) }
  sleep 0.2
  [pid, ((clock - t0) * 1000).round]
rescue
  stop(pid) if pid
  raise
end

def stop(pid)
  Process.kill(:TERM, -pid)
  Timeout.timeout(5) { Process.wait(pid) }
rescue Timeout::Error
  Process.kill(:KILL, -pid)
  Process.wait(pid)
rescue Errno::ESRCH, Errno::ECHILD
ensure
  wait_until { group(pid).empty? } rescue nil
end

def wrk(route, connections:, duration:, rate: nil)
  spec = ROUTES.fetch(route)
  tool = rate ? [WRK2, "-R#{rate}"] : ["wrk"]
  script = spec[:script] ? ["-s", spec[:script]] : []
  IO.popen(["taskset", "-c", WRK_CPUS, *tool, "-t#{[4, connections].min}", "-c#{connections}", "-d#{duration}s", "--latency", *spec.fetch(:headers, []), *script, "http://127.0.0.1:#{PORT}#{spec[:path]}"], err: [:child, :out], &:read)
end

def parse(output, rate)
  percentiles = rate ? { "50" => "50.000", "90" => "90.000", "99" => "99.000", "99.9" => "99.900", "99.99" => "99.990" } : { "50" => "50", "75" => "75", "90" => "90", "99" => "99" }
  {
    rps: output[/Requests\/sec:\s+([\d.]+)/, 1].to_f.round,
    requests: output[/(\d+) requests in/, 1].to_i,
    latency_ms: percentiles.to_h { |label, key| [label, to_ms(output[/^\s*#{Regexp.escape(key)}%\s+([\d.]+\w+)/, 1])] },
    socket_errors: output[/Socket errors: (.*)/, 1],
    non_2xx: output[/Non-2xx or 3xx responses: (\d+)/, 1].to_i,
  }
end

def measure(name:, workers:, route:, connections: 256, duration: 8, warmup: 2, rate: nil)
  return if ONLY && !ONLY.include?(name)
  pid, boot_ms = start(name, workers)
  wrk(route, connections:, duration: warmup) if warmup > 0
  peak = { rss: 0, pss: 0 }
  sampling = true
  sampler = Thread.new { while sampling; peak = memory_kb(pid).merge(peak) { |_, a, b| [a, b].max }; sleep 0.5; end }
  t0 = cpu_ticks(pid)
  output = wrk(route, connections:, duration:, rate:)
  t1 = cpu_ticks(pid)
  sampling = false
  sampler.join
  result = parse(output, rate)
  cpu_us = result[:requests].positive? ? ((t1 - t0).to_f / TICK / result[:requests] * 1e6).round(2) : nil
  { impl: name, workers:, route:, connections:, duration:, rate:, boot_ms:, cpu_us_per_request: cpu_us, peak_rss_kb: peak[:rss], peak_pss_kb: peak[:pss], **result }
ensure
  stop(pid) if pid
end

def repeat(n, **opts)
  runs = n.times.filter_map { measure(**opts) }
  return if runs.empty?
  runs.sort_by { it[:rps] }[n / 2].merge(samples: runs.map { it[:rps] })
end

def http_get(path)
  Socket.tcp("127.0.0.1", PORT) do |socket|
    socket.write("GET #{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    socket.read.split("\r\n\r\n", 2).last
  end
end

def upstream_count
  Socket.tcp("127.0.0.1", 9003) do |socket|
    socket.write("GET /__count HTTP/1.1\r\nConnection: close\r\n\r\n")
    socket.read.split("\r\n\r\n", 2).last.to_i
  end
end

def sharing(name)
  return if ONLY && !ONLY.include?(name)
  pid, = start(name, 4)
  served = parse(wrk("raw", connections: 64, duration: 4), nil)[:requests]
  scrapes = Array.new(8) { http_get("/metrics")[/class="2xx"\} (\d+)/, 1].to_i }
  sleep((0.5 - Time.now.to_f) % 1)
  limited = parse(wrk("free", connections: 64, duration: 10, rate: 5_000), 5_000)
  before = upstream_count
  catalog = parse(wrk("catalog", connections: 64, duration: 10, rate: 40_000), 40_000)
  fetches = upstream_count - before
  {
    impl: name, workers: 4,
    metrics: { served:, scrapes: },
    rate_limit: { limit_per_second: 1_000, offered_per_second: 5_000, duration: 10, requests: limited[:requests], allowed: limited[:requests] - limited[:non_2xx] },
    cache: { ttl: 1, urls: 1_000, rate: 40_000, duration: 10, requests: catalog[:requests], upstream_fetches: fetches },
  }
ensure
  stop(pid) if pid
end

def caching(name, workers:)
  return if ONLY && !ONLY.include?(name)
  pid, = start(name, workers)
  idle = memory_kb(pid)[:pss]
  before = upstream_count
  peak = 0
  sampling = true
  sampler = Thread.new { while sampling; peak = [peak, memory_kb(pid)[:pss]].max; sleep 0.25; end }
  result = parse(wrk("catalog-big", connections: 64, duration: 10, rate: 40_000), 40_000)
  sampling = false
  sampler.join
  {
    impl: name, workers:, body_kb: 64, urls: 1_000, ttl: 1, rate: 40_000, duration: 10,
    requests: result[:requests], upstream_fetches: upstream_count - before,
    pss_kb_idle: idle, pss_kb_peak: peak, pss_kb_end: memory_kb(pid)[:pss], latency_ms: result[:latency_ms],
  }
ensure
  stop(pid) if pid
end

def idle(name, workers:, connections:)
  return if ONLY && !ONLY.include?(name)
  pid, = start(name, workers)
  before = memory_kb(pid)
  holder = IO.popen([File.join(ROOT, "bench/hold/hold"), "-n", connections.to_s], err: [:child, :out])
  holder.gets if connections.positive?
  sleep 2
  after = memory_kb(pid)
  { impl: name, workers:, connections:, rss_kb_before: before[:rss], pss_kb_before: before[:pss], rss_kb: after[:rss], pss_kb: after[:pss] }
ensure
  Process.kill(:TERM, holder.pid) rescue nil
  holder&.close
  stop(pid) if pid
end

def profile(version, route)
  dump = File.join(VARIANTS, "profile-#{version}-#{route}.dump")
  script = version == "v1" ? File.join(VARIANTS, "v1/proxy.rb") : File.join(ROOT, "ruby/gateway.rb")
  path = version == "v1" ? { "raw" => "/raw/x", "api" => "/api/users?fields=id,name,email" }.fetch(route) : ROUTES.fetch(route)[:path]
  wait_until { port_free? }
  env = { "PATH" => "#{RUBIES["master"]}:#{ENV["PATH"]}", "MODE" => "thread", "WORKERS" => "1", "PROFILE_OUT" => dump, "PROFILE_TARGET" => script, **HEAP }
  pid = Process.spawn(env, "taskset", "-c", "0", "ruby", "--yjit", File.join(ROOT, "bench/profile.rb"), chdir: ROOT, pgroup: true, out: File::NULL, err: File::NULL)
  wait_until { listeners >= 1 }
  IO.popen(["taskset", "-c", WRK_CPUS, "wrk", "-t2", "-c32", "-d9s", *BENCH_KEY, "http://127.0.0.1:#{PORT}#{path}"], err: [:child, :out], &:read)
  wait_until(20) { File.exist?(dump) && File.size(dump) > 0 }
  sleep 0.5
  { version:, route:, **classify(Marshal.load(File.binread(dump))) }
ensure
  stop(pid) if pid
end

def classify(data)
  total = data[:samples].to_f
  shares = Hash.new(0)
  data[:frames].each_value do |frame|
    file, name = frame[:file].to_s, frame[:name].to_s
    bucket =
      if file.start_with?(File.join(ROOT, "ruby"), File.join(VARIANTS, "v1")) then "gateway Ruby code"
      elsif file.include?("/gems/async-") || file.include?("/gems/io-event") || file.include?("/gems/console") || name.start_with?("IO::Event") then "async and io-event"
      elsif name.start_with?("JSON::") then "json extension"
      elsif file == "<cfunc>" && name.match?(/\A(IO|BasicSocket|Socket|TCPSocket|Addrinfo)[#.]/) then "IO and syscalls"
      elsif file == "" then "garbage collector"
      else "Ruby core methods"
      end
    shares[bucket] += frame[:samples]
  end
  { samples: total.to_i, shares: shares.transform_values { (it / total * 100).round(1) } }
end

def record(scenario, runs)
  path = File.join(OUT, "#{scenario}.json")
  if ONLY && File.exist?(path) && runs.is_a?(Array)
    runs = JSON.parse(File.read(path), symbolize_names: true).reject { |run| ONLY.include?(run[:impl]) } + runs
  end
  File.write(path, JSON.pretty_generate(runs))
end

SCENARIOS = {
  "scaling" => -> {
    { "raw" => %w[go-std ruby-ractor ruby-fork ruby-fork-unsynced ruby-thread spinel], "api" => %w[go-std go-jsontext ruby-ractor ruby-fork ruby-fork-unsynced ruby-thread spinel], "hit" => %w[go-std ruby-ractor ruby-fork ruby-fork-unsynced ruby-thread spinel] }.flat_map do |route, impls|
      impls.product([1, 2, 4, 8]).filter_map do |impl, workers|
        next if ONLY && !ONLY.include?(impl)
        log "scaling #{route} #{impl} x#{workers}"
        repeat(3, name: impl, workers:, route:)&.tap { log "  #{it[:rps]} rps #{it[:samples]}" }
      end
    end
  },
  "sharing" => -> {
    %w[ruby-ractor ruby-fork ruby-fork-unsynced ruby-thread go-std spinel].filter_map do |impl|
      next if ONLY && !ONLY.include?(impl)
      log "sharing #{impl}"
      sharing(impl)&.tap { log "  metrics #{it[:metrics]} limit #{it[:rate_limit][:allowed]} fetches #{it[:cache][:upstream_fetches]}" }
    end
  },
  "caching" => -> {
    [*%w[ruby-ractor ruby-leaky ruby-fork ruby-fork-unsynced ruby-thread go-std spinel].product([4]), *%w[ruby-ractor ruby-leaky ruby-fork ruby-fork-unsynced].product([8])].filter_map do |impl, workers|
      next if ONLY && !ONLY.include?(impl)
      log "caching #{impl} x#{workers}"
      caching(impl, workers:)&.tap { log "  pss #{it[:pss_kb_peak]} kB fetches #{it[:upstream_fetches]} p99 #{it[:latency_ms]["99"]}ms" }
    end
  },
  "concurrency" => -> {
    [64, 256, 1024, 4096, 10_000].product([["go-std", 4], ["ruby-ractor", 4], ["ruby-leaky", 4], ["spinel", 4], ["go-std", 1], ["ruby-ractor", 1], ["spinel", 1]]).filter_map do |connections, (impl, workers)|
      next if ONLY && !ONLY.include?(impl)
      log "concurrency #{impl} x#{workers} c=#{connections}"
      measure(name: impl, workers:, route: "slow", connections:, duration: 10, warmup: 3)&.tap { log "  #{it[:rps]} rps p99 #{it[:latency_ms]["99"]}ms" }
    end
  },
  "latency" => -> {
    { "raw" => [[50_000, 100_000, 150_000], %w[go-std ruby-ractor ruby-fork ruby-fork-unsynced spinel]], "api" => [[5_000, 10_000, 20_000], %w[go-std go-jsontext ruby-ractor ruby-fork ruby-fork-unsynced spinel]] }.flat_map do |route, (rates, impls)|
      rates.product(impls).filter_map do |rate, impl|
        next if ONLY && !ONLY.include?(impl)
        log "latency #{route} #{impl} @#{rate}"
        measure(name: impl, workers: 4, route:, rate:, duration: 30, warmup: 2)&.tap { log "  p50 #{it[:latency_ms]["50"]} p99 #{it[:latency_ms]["99"]} p99.9 #{it[:latency_ms]["99.9"]}" }
      end
    end
  },
  "idle" => -> {
    [0, 1_000, 10_000].product(%w[go-std ruby-ractor ruby-fork ruby-fork-unsynced ruby-thread spinel]).filter_map do |connections, impl|
      next if ONLY && !ONLY.include?(impl)
      log "idle #{impl} c=#{connections}"
      idle(impl, workers: 4, connections:)&.tap { log "  pss #{it[:pss_kb]} kB" }
    end
  },
  "tuning" => -> {
    %w[raw api hit].product(%w[ruby-stock ruby-heap ruby-leaky ruby-ractor ruby-interp ruby-zjit spinel-stock spinel]).filter_map do |route, impl|
      next if ONLY && !ONLY.include?(impl)
      log "tuning #{route} #{impl}"
      repeat(3, name: impl, workers: 4, route:)&.tap { log "  #{it[:rps]} rps #{it[:samples]}" }
    end
  },
  "versions" => -> {
    %w[raw api hit].product(%w[ruby406-ractor ruby406-fork ruby-stock ruby-ractor], [1, 4]).filter_map do |route, impl, workers|
      next if ONLY && !ONLY.include?(impl)
      log "versions #{route} #{impl} x#{workers}"
      repeat(3, name: impl, workers:, route:)&.tap { log "  #{it[:rps]} rps #{it[:samples]}" }
    end
  },
  "profile" => -> {
    [%w[v1 raw], %w[v1 api], %w[v2 raw], %w[v2 api]].map do |version, route|
      log "profile #{version} #{route}"
      profile(version, route).tap { log "  #{it[:shares]}" }
    end
  },
  "loc" => -> {
    {
      "ruby" => [*Dir[File.join(ROOT, "ruby/{gateway.rb,lib/**/*.rb,bin/gateway}")]],
      "go" => [*Dir[File.join(ROOT, "go/*.go")]].reject { it.end_with?("_test.go") },
    }.transform_values { |files| files.sort.to_h { |f| [f.delete_prefix("#{ROOT}/"), File.readlines(f).count { it.strip != "" }] } }
  },
}

def environment
  {
    date: Time.now.utc.iso8601,
    cpu: File.read("/proc/cpuinfo")[/model name\s+: (.*)/, 1],
    kernel: `uname -r`.strip,
    rubies: RUBIES.transform_values { `#{it}/ruby -v`.strip },
    go: `go version`.strip,
    cores: CORES, upstream_cpus: UPSTREAM_CPUS, wrk_cpus: WRK_CPUS,
  }
end

upstream = Process.spawn("taskset", "-c", UPSTREAM_CPUS, File.join(ROOT, "bench/upstream/upstream"), "-ports", "9001,9002,9003,9004", pgroup: true, out: File::NULL, err: File::NULL)
at_exit { Process.kill(:TERM, -upstream) rescue nil }
wait_until { TCPSocket.new("127.0.0.1", 9004).close || true rescue false }
File.write(File.join(OUT, "environment.json"), JSON.pretty_generate(environment))
(ARGV.empty? ? SCENARIOS.keys : ARGV).each do |scenario|
  log "== #{scenario}"
  record(scenario, SCENARIOS.fetch(scenario).call)
end
