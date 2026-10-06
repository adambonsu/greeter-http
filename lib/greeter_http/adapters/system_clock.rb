# frozen_string_literal: true

require 'greeter/core'

module GreeterHttp
  module Adapters
    # Concrete Clock port backed by the system wall clock. Implements the
    # gem's abstract Greeter::Core::Ports::Clock (its #now raises until
    # implemented here).
    class SystemClock < Greeter::Core::Ports::Clock
      def now
        Time.now.utc
      end
    end
  end
end
