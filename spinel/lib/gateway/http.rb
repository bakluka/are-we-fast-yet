module Gateway
  module HTTP
    CRLF = "\r\n"
    HOP_BY_HOP = %w[connection keep-alive proxy-connection te trailer transfer-encoding upgrade]
    REASONS = { 200 => "OK", 404 => "Not Found", 429 => "Too Many Requests", 502 => "Bad Gateway" }

    class Headers
      def self.parse(lines)
        new(lines.to_h do |line|
          name, value = line.split(":", 2)
          [name.downcase, value.strip]
        end)
      end

      def initialize(fields = {})
        @fields = fields
      end

      def [](name) = @fields[name]
      def merge(fields) = Headers.new(@fields.merge(fields))
      def end_to_end = Headers.new(@fields.except(*HOP_BY_HOP))
      def content_length = @fields["content-length"].to_i

      def to_s
        @fields.map { |name, value| "#{name}: #{value}#{CRLF}" }.join
      end
    end

    Request = Data.define(:verb, :path, :query, :headers, :body, :client) do
      def target = query ? "#{path}?#{query}" : path
      def params = query.to_s.split("&").to_h { it.split("=", 2) }
      def get? = verb == "GET"
      def keep_alive? = headers["connection"] != "close"
      def head = "#{verb} #{target} HTTP/1.1#{CRLF}#{headers}#{CRLF}"
    end

    Response = Data.define(:status, :reason, :headers, :body) do
      def self.text(status, body = "#{REASONS[status]}\n")
        headers = Headers.new("content-type" => "text/plain", "content-length" => body.bytesize.to_s)
        new(status:, reason: REASONS[status], headers:, body:)
      end

      def ok? = status == 200
      def json? = headers["content-type"]&.start_with?("application/json")
      def with_header(name, value) = with(headers: headers.merge(name => value))
      def with_body(body) = with(body:, headers: headers.merge("content-length" => body.bytesize.to_s))
      def head = "HTTP/1.1 #{status} #{reason}#{CRLF}#{headers}#{CRLF}"
    end

    class Stream
      def initialize(socket)
        @socket = socket
      end

      def read_request(client:)
        line = @socket.gets(CRLF) or return
        verb, target = line.split(" ", 3)
        path, query = target.split("?", 2)
        headers = read_headers
        Request.new(verb:, path:, query:, headers:, body: read_body(headers), client:)
      end

      def read_response
        _, status, reason = read_line.split(" ", 3)
        headers = read_headers
        Response.new(status: status.to_i, reason: reason.chomp, headers:, body: read_body(headers))
      end

      def write(message) = @socket.write(message.head, message.body)
      def close = @socket.close

      private

      def read_headers
        lines = []
        until (line = read_line) == CRLF
          lines << line
        end
        Headers.parse(lines)
      end

      def read_line = @socket.gets(CRLF) || raise(EOFError)

      def read_body(headers)
        length = headers.content_length
        length.zero? ? "" : @socket.read(length)
      end
    end
  end
end
