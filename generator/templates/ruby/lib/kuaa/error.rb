# frozen_string_literal: true

require "json"

module Kuaa
  # A request the API refused.
  #
  # +code+ is the API's, the one to branch on: unauthenticated, forbidden,
  # not_found, conflict, idempotency_key_reused, validation_failed,
  # payment_required, malformed_json, body_too_large, rate_limited…
  # +message+ is the API's explanation, +fields+ says, for validation_failed,
  # what is wrong with each field, and +retry_after+ is how many seconds the
  # API asked to wait, on a 429 or a 503.
  class Error < StandardError
    attr_reader :status, :code, :message, :fields, :retry_after, :request_id

    def initialize(status, code, message = "", fields = {}, retry_after = nil, request_id = nil)
      @status = status
      @code = code
      @message = message
      @fields = fields
      @retry_after = retry_after
      @request_id = request_id
      super(message.empty? ? "kuaa: #{status} #{code}" : "kuaa: #{status} #{code}: #{message}")
    end

    # What Ruby prints for an error nobody rescued: the status and code too.
    def detailed_message(highlight: false, **)
      highlight ? "\e[1m#{self} (#{self.class.name})\e[m" : "#{self} (#{self.class.name})"
    end

    # The error a response with a status of 300 or more is.
    def self.from_response(status, headers, body)
      problem = begin
        loaded = JSON.parse(body.to_s.empty? ? "{}" : body)
        loaded.is_a?(Hash) && loaded["error"].is_a?(Hash) ? loaded["error"] : {}
      rescue JSON::ParserError
        {} # A refusal without a JSON body is still a refusal.
      end
      retry_after = headers["retry-after"].to_s.strip
      new(status, problem["code"].to_s, problem["message"].to_s, problem["fields"] || {},
          retry_after.match?(/\A\d+\z/) ? retry_after.to_i : nil, headers["x-request-id"])
    end
  end
end
