module Gateway
  class Server
    def initialize(app, port:)
      @app = app
      @port = port
    end

    def run
      listener = listen
      Sync do
        loop do
          socket, address = listener.accept
          Async { serve(socket, address.ip_address) }
        end
      end
    end

    private

    def listen
      Socket.new(:INET, :STREAM).tap do |socket|
        socket.setsockopt(:SOCKET, :REUSEADDR, true)
        socket.setsockopt(:SOCKET, :REUSEPORT, true)
        socket.bind(Addrinfo.tcp("0.0.0.0", @port))
        socket.listen(Socket::SOMAXCONN)
      end
    end

    def serve(socket, client)
      socket.setsockopt(:TCP, :NODELAY, true)
      stream = HTTP::Stream.new(socket)
      while (request = stream.read_request(client:))
        stream.write(@app.call(request))
        break unless request.keep_alive?
      end
    rescue SystemCallError, IOError
    ensure
      stream.close
    end
  end
end
