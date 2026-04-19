module Gateway
  class Cache
    Entry = Data.define(:response, :expires_at) do
      def fresh?(now) = now < expires_at
    end

    def initialize(ttl:, entries: Ratomic::Map.new)
      @ttl = ttl
      @entries = entries
      freeze
    end

    def kept_by(link, name) = Cache.new(ttl: @ttl, entries: link.shelf(name))

    def call(request)
      return yield(request) unless request.get?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = @entries[request.target]
      return entry.response.with_headers("x-cache" => "hit") if entry&.fresh?(now)

      response = yield(request)
      store(request.target, response, now) if response.ok?
      response.with_headers("x-cache" => "miss")
    end

    private

    def store(key, response, now)
      @entries[-key] = Ractor.make_shareable(Entry.new(response:, expires_at: now + @ttl))
    end
  end
end
