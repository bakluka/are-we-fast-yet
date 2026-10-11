# Are We Fast Yet?

One API gateway, two languages. Ruby (Ractors + async Fibers) and Go, same features,
same machine, same cores. Routes, rate-limits, caches, rewrites JSON, reports Prometheus
metrics. All state shared across workers. The question: how close does Ruby get?

## Numbers

Ryzen 9800X3D, Ruby master (YJIT), Go 1.25.5, four cores.

**Throughput (req/s):**

| Route | Ractors | Forks (keeper) | Forks (solo) | Threads | Go |
|---|---:|---:|---:|---:|---:|
| Pass-through | 228,250 | 209,514 | 235,050 | 64,588 | 424,367 |
| JSON rewrite | 34,618 | 29,584 | 33,847 | 8,513 | 24,688 / 62,101 |
| Cache hit | 534,040 | 170,617 | 527,587 | 139,252 | 831,978 |

Go's two JSON numbers: `encoding/json` vs a hand-rolled streaming filter.
Ruby beats the first one.

**Shared state** (free key: 1,000/s limit, offered 5,000/s for 10 s):

| | Allowed | Upstream fetches | Metrics |
|---|---:|---:|---|
| Ractors | 11,007 | 10,000 | all |
| Forks (keeper) | 11,000 | 10,000 | all |
| Forks (solo) | 38,870 | 38,729 | ~25% |
| Go | 11,000 | 10,000 | all |

Forks without IPC each keep their own windows, caches, and counters.
Ractors share them in one address space with no serialization overhead. That's the whole pitch.

## Layout

```
ruby/           Gateway in Ruby -- Ractor, thread, or fork from the same code
go/             Gateway in Go -- encoding/json and jsontext builds
spinel/         Same gateway on Matz's Spinel AOT compiler (threads, no GVL)
bench/run.rb    Harness: pins CPUs, runs wrk/wrk2, records everything
bench/upstream  Backend server (12 KB JSON, configurable delay and body size)
bench/results   Data from the last full run
bench/report    Write-up generator
patches/        ratomic build fix for master; draft Ractor GC bug report
```

## Setup

Ruby master with YJIT. ratomic needs a small patch for master's changed `rb_data_type_t`:

```sh
gem install async
git clone https://github.com/mperham/ratomic && cd ratomic
git apply /path/to/patches/ratomic-magnus-0.9.patch
gem build ratomic.gemspec && gem install ./ratomic-0.4.3.gem
```

Go 1.25+:

```sh
(cd bench/upstream && go build)
(cd go && go build -o bin/gateway-std . && GOEXPERIMENT=jsonv2 go build -o bin/gateway-jsontext .)
```

## Run

```sh
bench/upstream/upstream -ports 9001,9002,9003,9004 &
MODE=ractor WORKERS=4 ruby/bin/gateway

curl -H 'X-Api-Key: free' 'localhost:8080/api/users?fields=id,name,email,created_at'
curl localhost:8080/metrics
```

Ractors need a once-a-second `GC.start` nudge because master doesn't collect
frozen garbage on its own yet (bug report in `patches/`).

## Benchmark

```sh
ruby bench/run.rb                  # all scenarios, ~95 min
ruby bench/run.rb scaling sharing  # pick some
```

Pins gateway, upstream, and wrk to separate cores. Each point is the median
of three 8 s runs. Everything in `bench/results/`; rebuild the report with
`ruby bench/report/build.rb`.
