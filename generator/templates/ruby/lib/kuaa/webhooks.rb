# frozen_string_literal: true

require "json"
require "openssl"

# Verifying the webhooks KUAA sends.
module Kuaa
  WEBHOOK_HEADER_DELIVERY_ID = "X-Arandu-Delivery-Id"
  WEBHOOK_HEADER_TIMESTAMP = "X-Arandu-Timestamp"
  WEBHOOK_HEADER_SIGNATURE = "X-Arandu-Signature"

  # How far from now a delivery's timestamp may be, either way, in seconds.
  WEBHOOK_TOLERANCE_SECONDS = 300

  # One signature per secret still signing: the current one and at most five
  # previous ones.
  WEBHOOK_MAX_SIGNATURES = 6
  private_constant :WEBHOOK_MAX_SIGNATURES

  # A delivery KUAA did not sign with the secret, or signed too long ago.
  class WebhookVerificationError < StandardError
    def initialize(message = "kuaa: webhook signature does not verify")
      super
    end
  end

  # Checks a delivery KUAA sent and answers its event, a CloudEvents 1.0
  # envelope.
  #
  # The signature is
  # +sha256=hex(HMAC-SHA256(secret, timestamp + "." + delivery_id + "." + body))+,
  # keyed with the endpoint's secret exactly as it was shown; during a
  # rotation the X-Arandu-Signature header comes once per secret, and any one
  # matching is enough. A timestamp more than five minutes from now is
  # refused. Pass the body exactly as it arrived, before parsing it;
  # +headers+ is a hash of the request's headers, in any case, each a String
  # or an Array of its lines, or a Rack env. Deduplicate on the event's id:
  # delivery is at least once.
  #
  # @return [WebhookEvent]
  # @raise [WebhookVerificationError]
  def self.verify_webhook(secret, headers, body, now: Time.now)
    raise ArgumentError, "kuaa: the webhook secret is empty" if secret.nil? || secret.empty?

    raw = body.to_s.b
    delivery = webhook_values(headers, WEBHOOK_HEADER_DELIVERY_ID).first.to_s.strip
    stamp = webhook_values(headers, WEBHOOK_HEADER_TIMESTAMP).first.to_s.strip
    raise WebhookVerificationError if delivery.empty? || !stamp.match?(/\A\d+\z/)
    raise WebhookVerificationError if (now.to_i - stamp.to_i).abs > WEBHOOK_TOLERANCE_SECONDS

    signature = webhook_values(headers, WEBHOOK_HEADER_SIGNATURE).join(",")
    entries = signature.split(",", -1)
    raise WebhookVerificationError if signature.strip.empty? || entries.length > WEBHOOK_MAX_SIGNATURES

    given = entries.map do |entry|
      digest = entry.strip.delete_prefix("sha256=")
      raise WebhookVerificationError unless entry.strip.start_with?("sha256=") && digest.match?(/\A\h{64}\z/)

      [digest].pack("H*")
    end
    expected = OpenSSL::HMAC.digest("SHA256", secret.b, "#{stamp}.#{delivery}.".b + raw)
    matched = false
    given.each { |each| matched = true if OpenSSL.fixed_length_secure_compare(each, expected) }
    raise WebhookVerificationError unless matched

    WebhookEvent.from_hash(JSON.parse(raw.force_encoding(Encoding::UTF_8)))
  end

  # Every value of a header, looked up in any case; a Rack env's
  # HTTP_X_ARANDU_SIGNATURE names X-Arandu-Signature.
  def self.webhook_values(headers, name)
    wanted = name.downcase
    headers.each_with_object([]) do |(key, value), out|
      out.concat(Array(value).map(&:to_s)) if key.to_s.downcase.tr("_", "-").delete_prefix("http-") == wanted
    end
  end
  private_class_method :webhook_values
end
