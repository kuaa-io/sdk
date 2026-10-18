# frozen_string_literal: true

module Kuaa
  # What every resource and every body shares: its members, read as a hash and
  # compared by value.
  module Value
    def to_h
      self.class::MEMBERS.to_h { |name| [name, instance_variable_get(:"@#{name}")] }
    end

    def ==(other)
      other.class == self.class && other.to_h == to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end

    def inspect
      "#<#{self.class.name} #{to_h.map { |name, value| "#{name}=#{value.inspect}" }.join(", ")}>"
    end
    alias to_s inspect
  end

  # A resource the API answers, built from its JSON and frozen.
  class Model
    include Value
  end

  # The body of a write: built with keyword arguments, sent with the API's
  # names, an optional field left unset left out.
  class Params
    include Value

    # The params as they are, or built from a hash of their names.
    def self.coerce(params)
      case params
      when self then params
      when Hash then new(**params.transform_keys(&:to_sym))
      else raise ArgumentError, "kuaa: #{name} is built from a Hash, not #{params.class}"
      end
    end
  end
end

module Kuaa
  # One file of a multipart body: +filename+ is the name the part carries,
  # such as frente.jpg, and +content_type+ the file's media type, image/jpeg
  # or image/png.
  class FilePart
    attr_reader :filename, :data, :content_type

    def initialize(filename, data, content_type = "application/octet-stream")
      @filename = filename
      @data = data.to_s.b
      @content_type = content_type
      freeze
    end

    # A file read from disk.
    def self.from_path(path, content_type = "application/octet-stream")
      new(::File.basename(path), ::File.binread(path), content_type)
    end
  end

  # What the API said about an answer, beside its body: +livemode+ is the
  # Kuaa-Livemode header (true for live, false for a sandbox, nil when
  # absent), +environment+ the Kuaa-Environment header, +idempotent_replayed+
  # says the answer is the stored answer of an earlier request with the same
  # Idempotency-Key, and +request_id+ is the X-Request-ID header.
  class ResponseInfo < Model
    MEMBERS = %i[status livemode environment idempotent_replayed request_id].freeze

    attr_reader(*MEMBERS)

    def initialize(status:, livemode:, environment:, idempotent_replayed:, request_id:)
      @status = status
      @livemode = livemode
      @environment = environment
      @idempotent_replayed = idempotent_replayed
      @request_id = request_id
      freeze
    end

    # The info of an answer's status and headers, in lower case.
    def self.from_headers(status, headers)
      livemode = { "true" => true, "false" => false }[headers["kuaa-livemode"]]
      new(status: status, livemode: livemode, environment: headers["kuaa-environment"],
          idempotent_replayed: headers["idempotent-replayed"] == "true", request_id: headers["x-request-id"])
    end
  end
end
