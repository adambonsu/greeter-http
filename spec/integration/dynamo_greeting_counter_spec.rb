# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require_relative '../contracts/greeting_counter_contract'

# The DynamoDB adapter must satisfy the SAME contract as the in-memory one,
# exercised against a real DynamoDB Local instance. These examples are tagged
# :integration and are skipped unless DYNAMODB_ENDPOINT is set (see spec_helper).
RSpec.describe 'GreeterHttp::Adapters::DynamoDbGreetingCounter', :integration do
  let(:endpoint)   { ENV.fetch('DYNAMODB_ENDPOINT') }
  let(:table_name) { ENV.fetch('DYNAMODB_TABLE', 'greeter-http-test') }

  let(:client) do
    require 'aws-sdk-dynamodb'
    Aws::DynamoDB::Client.new(
      endpoint: endpoint,
      region: ENV.fetch('AWS_REGION', 'eu-west-1'),
      access_key_id: ENV.fetch('AWS_ACCESS_KEY_ID', 'local'),
      secret_access_key: ENV.fetch('AWS_SECRET_ACCESS_KEY', 'local')
    )
  end

  # Fresh table per run so the contract's "first increment returns 1" holds.
  before do
    begin
      client.delete_table(table_name: table_name)
      client.wait_until(:table_not_exists, table_name: table_name)
    rescue Aws::DynamoDB::Errors::ResourceNotFoundException
      # fine, nothing to delete
    end

    client.create_table(
      table_name: table_name,
      billing_mode: 'PAY_PER_REQUEST',
      key_schema: [
        { attribute_name: 'PK', key_type: 'HASH' },
        { attribute_name: 'SK', key_type: 'RANGE' }
      ],
      attribute_definitions: [
        { attribute_name: 'PK', attribute_type: 'S' },
        { attribute_name: 'SK', attribute_type: 'S' }
      ]
    )
    client.wait_until(:table_exists, table_name: table_name)
  end

  after do
    client.delete_table(table_name: table_name)
  rescue Aws::DynamoDB::Errors::ResourceNotFoundException
    nil
  end

  it_behaves_like 'a greeting counter' do
    let(:counter) do
      GreeterHttp::Adapters::DynamoDbGreetingCounter.new(
        client: client,
        table_name: table_name,
        ttl_seconds: 86_400
      )
    end
  end
end
