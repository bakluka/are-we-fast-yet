require "json"

doc = File.read(File.join(__dir__, "doc.json"))
fields = %w[id name email]
trim = proc { JSON.generate(JSON.parse(doc).map { it.slice(*fields) }) }
5_000.times(&trim)
best = 5.times.map do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  50_000.times(&trim)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / 50_000 * 1e6
end.min
puts format("%-8s %.1f us/op", RUBY_DESCRIPTION[/\+(YJIT|ZJIT)/, 1] || "interp", best)
