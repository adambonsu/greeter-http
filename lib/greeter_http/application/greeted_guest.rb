# frozen_string_literal: true

module GreeterHttp
  module Application
    # Result of the GreetAndCount use case: the normalized guest name, the
    # running greeting count, when the guest was greeted, and whether this was
    # a replay of a previously recorded request.
    GreetedGuest = Struct.new(:guest_name, :count, :greeted_at, :replayed, keyword_init: true) do
      def replayed?
        replayed
      end
    end
  end
end
