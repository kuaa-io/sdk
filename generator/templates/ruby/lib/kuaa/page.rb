# frozen_string_literal: true

module Kuaa
  # One page of a list, and where the next one starts: +next_cursor+ is nil on
  # the last one.
  class Page
    attr_reader :items, :next_cursor

    def initialize(items:, next_cursor:, has_more:)
      @items = items.freeze
      @next_cursor = next_cursor
      @has_more = has_more
      freeze
    end

    # Another page follows.
    def has_more? # rubocop:disable Naming/PredicateName
      @has_more
    end

    # Builds a page from the API's envelope, its items under +field+, each
    # through the block.
    def self.from_envelope(envelope, field, &item)
      meta = envelope["meta"] || {}
      next_cursor = meta["next_cursor"]
      has_more = meta.key?("has_more") ? meta["has_more"] == true : !(next_cursor.nil? || next_cursor.empty?)
      new(items: ((envelope["data"] || {})[field] || []).map(&item), next_cursor: next_cursor, has_more: has_more)
    end

    # Walks pages from +cursor+ until the last one, yielding every item;
    # +fetch+ answers the page of the cursor it is given.
    def self.iterate(cursor, &fetch)
      Enumerator.new do |yielder|
        loop do
          page = fetch.call(cursor)
          page.items.each { |item| yielder << item }
          break if !page.has_more? || page.next_cursor.nil? || page.next_cursor.empty?

          cursor = page.next_cursor
        end
      end
    end
  end
end
