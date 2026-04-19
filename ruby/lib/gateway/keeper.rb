module Gateway
  class Keeper
    ANSWERED = %i[add count get].freeze

    def initialize
      @path = File.join(Dir.tmpdir, "gateway-#{Process.pid}.sock")
      @server = UNIXServer.new(@path)
      @tallies = Hash.new { |tallies, name| tallies[name] = Hash.new(0) }
      @shelves = Hash.new { |shelves, name| shelves[name] = {} }
    end

    def link = Link.new(@path)

    def run
      Sync do
        loop do
          socket = @server.accept
          Async { serve(socket) }
        end
      end
    ensure
      File.unlink(@path)
    end

    private

    def serve(socket)
      while (message = Wire.read(socket))
        answer = handle(*message)
        Wire.write(socket, answer) if ANSWERED.include?(message.first)
      end
    ensure
      socket.close
    end

    def handle(verb, name, key, value = nil)
      case verb
      in :add then @tallies[name][key] += value
      in :count then key.map { @tallies[name][it] }
      in :merge then key.each { |counted, by| @tallies[name][counted] += by }
      in :delete then @tallies[name].delete(key)
      in :get then @shelves[name][key]
      in :put then @shelves[name][key] = value
      end
    end

    module Wire
      def self.write(socket, message)
        payload = Marshal.dump(message)
        socket.write([payload.bytesize].pack("N"), payload)
      end

      def self.read(socket)
        size = socket.read(4) or return
        Marshal.load(socket.read(size.unpack1("N")))
      end
    end

    class Link
      def initialize(path)
        @path = path
        @idle = []
      end

      def tally(name) = Tally.new(self, name)
      def shelf(name) = Shelf.new(self, name)
      def batch(name) = Batch.new(tally(name))

      def ask(*message) = checkout { |socket| Wire.write(socket, message).then { Wire.read(socket) } }
      def tell(*message) = checkout { |socket| Wire.write(socket, message) }

      private

      def checkout
        socket = @idle.pop || UNIXSocket.new(@path)
        yield(socket).tap { @idle.push(socket) }
      rescue
        socket&.close
        raise
      end
    end

    Tally = Data.define(:link, :name) do
      def add(key, by = 1) = link.ask(:add, name, key, by)
      def merge(counts) = link.tell(:merge, name, counts)
      def delete(key) = link.tell(:delete, name, key)
      def values_at(*keys) = link.ask(:count, name, keys)
    end

    Shelf = Data.define(:link, :name) do
      def [](key) = link.ask(:get, name, key)&.then { Marshal.load(it) }

      def []=(key, value)
        link.tell(:put, name, key, Marshal.dump(value))
      end
    end

    class Batch
      def initialize(tally, every: 0.01)
        @tally = tally
        @pending = Hash.new(0)
        @lock = Mutex.new
        Thread.new { loop { sleep every; flush } }
      end

      def add(key, by = 1) = @lock.synchronize { @pending[key] += by }

      def values_at(*keys)
        flush
        @tally.values_at(*keys)
      end

      def flush
        counts = @lock.synchronize { @pending.tap { @pending = Hash.new(0) } }
        @tally.merge(counts) unless counts.empty?
      end
    end
  end
end
