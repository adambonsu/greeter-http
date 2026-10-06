# frozen_string_literal: true

require 'time'
require 'greeter/core'

module GreeterHttp
  module Adapters
    # Concrete GreetingPresenter port that renders a greeting as a JSON-ready
    # hash. Implements the gem's abstract Greeter::Core::Ports::GreetingPresenter.
    #
    # The running count is not part of a core Greeting, so #present covers the
    # greeting fields; the Rack layer merges the count into the response body.
    class JsonPresenter < Greeter::Core::Ports::GreetingPresenter
      def present(greeting)
        {
          guest_name: greeting.guest_name.display,
          greeting: "Hello, #{greeting.guest_name.display}!",
          greeted_at: iso8601(greeting.greeted_at)
        }
      end

      # Full HTTP response body for a greeting result, including the running
      # count (which is not part of a core Greeting). String keys so the JSON
      # body reads naturally for clients.
      def present_count(guest_name:, count:, greeted_at:)
        {
          'guest_name' => guest_name,
          'greeting' => "Hello, #{guest_name}!",
          'count' => count,
          'greeted_at' => iso8601(greeted_at)
        }
      end

      private

      def iso8601(time)
        time.respond_to?(:utc) ? time.utc.iso8601 : time.to_s
      end
    end
  end
end
