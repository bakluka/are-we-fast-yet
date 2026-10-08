module Gateway
  class Server
    def initialize(app, port:)
      @app = app
      @port = port
    end

    def run
      listener = TCPServer.new("0.0.0.0", @port)
      loop do
        socket = listener.accept
        Thread.new { serve(socket) }
      end
    end

    private

    def serve(socket)
      stream = HTTP::Stream.new(socket)
      client = socket.remote_address.ip_address
      while (request = stream.read_request(client:))
        stream.write(@app.call(request))
        break unless request.keep_alive?
      end
    rescue SystemCallError, IOError
    ensure
      socket.close
    end
  end
end
