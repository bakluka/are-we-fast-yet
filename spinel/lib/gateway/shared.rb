module Gateway
  class Counter
    def initialize
      @value = 0
      @lock = Mutex.new
    end

    def increment(by) = @lock.synchronize { @value += by }
    def decrement(by) = @lock.synchronize { @value -= by }
    def read = @value
  end

  class SharedMap
    def initialize
      @entries = {}
      @lock = Mutex.new
    end

    def [](key) = @lock.synchronize { @entries[key] }
    def delete(key) = @lock.synchronize { @entries.delete(key) }

    def []=(key, value)
      @lock.synchronize { @entries[key] = value }
    end
  end
end
