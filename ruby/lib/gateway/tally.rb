module Gateway
  class Tally
    def initialize(keys = [])
      @counters = Ratomic::Map.new
      keys.each { @counters[it] = Ratomic::Counter.new }
      freeze
    end

    def add(key, by = 1) = (@counters[key] ||= Ratomic::Counter.new).increment(by)
    def delete(key) = @counters.delete(key)
    def values_at(*keys) = keys.map { @counters[it]&.read || 0 }
  end
end
