module Gateway
  class Metrics
    BUCKETS = [0.5, 1, 2.5, 5, 10, 25, 50, 100, 250, Float::INFINITY].freeze
    CLASSES = 1..5

    def initialize
      @responses = CLASSES.to_h { [it, Counter.new] }.freeze
      @latency = BUCKETS.to_h { [it, Counter.new] }.freeze
      freeze
    end

    def call(request)
      return report if request.path == "/metrics"

      started = now
      response = yield(request)
      record(response, now - started)
      response
    end

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)

    def record(response, elapsed)
      @responses[response.status / 100].increment(1)
      @latency[BUCKETS.find { elapsed <= it }].increment(1)
    end

    def report
      HTTP::Response.text(200, [*response_lines, *latency_lines].join("\n") + "\n")
    end

    def response_lines
      @responses.map { |klass, counter| %(gateway_responses_total{class="#{klass}xx"} #{counter.read}) }
    end

    def latency_lines
      seen = 0
      @latency.map do |bucket, counter|
        seen += counter.read
        %(gateway_request_duration_ms_bucket{le="#{bucket.infinite? ? "+Inf" : bucket}"} #{seen})
      end
    end
  end
end
