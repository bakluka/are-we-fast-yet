module Gateway
  class Cache
    Entry = Data.define(:response, :expires_at) do
      def fresh?(now) = now < expires_at
    end

    def initialize(ttl:)
      @ttl = ttl
      @entries = SharedMap.new
      freeze
    end

    def call(request)
      return yield(request) unless request.get?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = @entries[request.target]
      return entry.response.with_header("x-cache", "hit") if entry&.fresh?(now)

      response = yield(request)
      store(request.target, response, now) if response.ok?
      response.with_header("x-cache", "miss")
    end

    private

    def store(key, response, now)
      @entries[key] = Entry.new(response:, expires_at: now + @ttl)
    end
  end
end
