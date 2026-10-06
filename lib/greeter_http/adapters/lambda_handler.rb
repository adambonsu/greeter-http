# frozen_string_literal: true

require 'json'
require 'stringio'
require 'uri'
require 'rack'

module GreeterHttp
  module Adapters
    # Thin AWS Lambda adapter: translates an API Gateway HTTP API (payload
    # format 2.0) event into a Rack env, calls the Rack app, and translates the
    # Rack response back into the API Gateway response shape. No business logic.
    class LambdaHandler
      def initialize(app:)
        @app = app
      end

      def call(event:, context: nil)
        env = rack_env(event)
        status, headers, body = @app.call(env)

        {
          'statusCode' => status,
          'headers' => stringify(headers),
          'body' => join_body(body),
          'isBase64Encoded' => false
        }
      end

      private

      def rack_env(event)
        http = event.fetch('requestContext', {}).fetch('http', {})
        method = http['method'] || event['httpMethod'] || 'GET'
        path = http['path'] || event['rawPath'] || '/'
        headers = event['headers'] || {}
        body = decoded_body(event)

        env = {
          'REQUEST_METHOD' => method,
          'PATH_INFO' => path,
          'QUERY_STRING' => event['rawQueryString'].to_s,
          'SERVER_NAME' => 'lambda',
          'SERVER_PORT' => '443',
          'rack.input' => StringIO.new(body),
          'rack.errors' => $stderr,
          'rack.url_scheme' => 'https'
        }

        headers.each do |name, value|
          key = "HTTP_#{name.to_s.upcase.tr('-', '_')}"
          env[key] = value.to_s
        end
        env['CONTENT_TYPE'] = headers['content-type'] || headers['Content-Type'] if headers
        env
      end

      def decoded_body(event)
        raw = event['body'].to_s
        if event['isBase64Encoded']
          require 'base64'
          Base64.decode64(raw)
        else
          raw
        end
      end

      def stringify(headers)
        (headers || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
      end

      def join_body(body)
        parts = body.map { |p| p }
        parts.join
      ensure
        body.close if body.respond_to?(:close)
      end
    end
  end
end
