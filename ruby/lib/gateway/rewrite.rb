module Gateway
  Rewrite = Data.define(:redact) do
    def kept_by(*) = self

    def call(request)
      response = yield(request)
      return response unless response.json?

      document = JSON.parse(response.body)
      fields = request.params["fields"]&.split(",")
      document = document.map { it.slice(*fields) } if fields
      response.with_body(JSON.generate(reshape(document)))
    end

    private

    def reshape(node)
      case node
      in Hash then node.to_h { |key, value| [camelize(key), redact.include?(key) ? mask(value) : reshape(value)] }
      in Array then node.map { reshape(it) }
      else node
      end
    end

    def camelize(key)
      head, *tail = key.split("_")
      [head, *tail.map(&:capitalize)].join
    end

    def mask(email)
      name, domain = email.split("@", 2)
      "#{name[0]}***@#{domain}"
    end
  end
end
