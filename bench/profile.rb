require "stackprof"

Thread.new do
  sleep 2
  StackProf.start(mode: :cpu, interval: 200, raw: true)
  sleep 6
  StackProf.stop
  StackProf.results(ENV.fetch("PROFILE_OUT"))
end

load ENV.fetch("PROFILE_TARGET")
