# shareable_constant_value: literal

module Gateway
  class Metrics
    BUCKETS = [0.5, 1, 2.5, 5, 10, 25, 50, 100, 250, Float::INFINITY].freeze
    CLASSES = 1..5

    def initialize(responses = Tally.new(CLASSES), latency = Tally.new(BUCKETS))
      @responses = responses
      @latency = latency
      freeze
    end

    def kept_by(link) = Metrics.new(link.batch("responses"), link.batch("latency"))

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
      @responses.add(response.status / 100)
      @latency.add(BUCKETS.find { elapsed <= it })
    end

    def report
      HTTP::Response.text(200, [*response_lines, *latency_lines].join("\n") + "\n")
    end

    def response_lines
      CLASSES.zip(@responses.values_at(*CLASSES)).map { |klass, count| %(gateway_responses_total{class="#{klass}xx"} #{count}) }
    end

    def latency_lines
      seen = 0
      BUCKETS.zip(@latency.values_at(*BUCKETS)).map do |bucket, count|
        seen += count
        %(gateway_request_duration_ms_bucket{le="#{bucket.infinite? ? "+Inf" : bucket}"} #{seen})
      end
    end
  end
end
