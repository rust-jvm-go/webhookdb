# frozen_string_literal: true

require "support/shared_examples_for_replicators"

RSpec.describe Webhookdb::Replicator::IncreaseTransactionV1, :db do
  it_behaves_like "a replicator", "increase_transaction_v1" do
    let(:body) do
      JSON.parse(<<~J)
        {
          "event_id": "transaction_event_123",
          "event": "created",
          "created_at": "2020-01-31T23:59:59Z",
          "data": {
            "account_id": "account_in71c4amph0vgo2qllky",
            "amount": 100,
            "currency": "USD",
            "created_at": "2020-01-31T23:59:59Z",
            "description": "Frederick S. Holmes",
            "id": "transaction_uyrp7fld2ium70oa7oi",
            "route_id": "account_number_v18nkfqm6afpsrvy82b2",
            "route_type": "account_number",
            "source": {
              "category": "inbound_ach_transfer",
              "inbound_ach_transfer": {
                "amount": 100,
                "originator_company_name": "BIG BANK",
                "originator_company_descriptive_date": null,
                "originator_company_discretionary_data": null,
                "originator_company_entry_description": "RESERVE",
                "originator_company_id": "0987654321",
                "receiver_id_number": "12345678900",
                "receiver_name": "IAN CREASE",
                "trace_number": "021000038461022"
              }
            },
            "type": "transaction"
          }
        }
      J
    end
    let(:expected_data) { body["data"] }
  end

  it_behaves_like "a replicator that prevents overwriting new data with old", "increase_transaction_v1" do
    let(:old_body) do
      JSON.parse(<<~J)
        {
          "event_id": "transaction_event_123",
          "event": "created",
          "created_at": "2020-01-31T23:59:59Z",
          "data": {
            "account_id": "account_in71c4amph0vgo2qllky",
            "amount": 100,
            "currency": "USD",
            "created_at": "2020-01-31T23:59:59Z",
            "description": "Frederick S. Holmes",
            "id": "transaction_uyrp7fld2ium70oa7oi",
            "route_id": "account_number_v18nkfqm6afpsrvy82b2",
            "route_type": "account_number",
            "source": {
              "category": "inbound_ach_transfer",
              "inbound_ach_transfer": {
                "amount": 100,
                "originator_company_name": "BIG BANK",
                "originator_company_descriptive_date": null,
                "originator_company_discretionary_data": null,
                "originator_company_entry_description": "RESERVE",
                "originator_company_id": "0987654321",
                "receiver_id_number": "12345678900",
                "receiver_name": "IAN CREASE",
                "trace_number": "021000038461022"
              }
            },
            "type": "transaction"
          }
        }
      J
    end
    let(:new_body) do
      JSON.parse(<<~J)
        {
          "event_id": "transaction_event_456",
          "event": "updated",
          "created_at": "2020-02-20T23:59:59Z",
          "data": {
            "account_id": "account_in71c4amph0vgo2qllky",
            "amount": 100,
            "currency": "USD",
            "created_at": "2020-01-31T23:59:59Z",
            "description": "Frederick S. Holmes",
            "id": "transaction_uyrp7fld2ium70oa7oi",
            "route_id": "account_number_v18nkfqm6afpsrvy82b2",
            "route_type": "account_number",
            "source": {
              "category": "inbound_ach_transfer",
              "inbound_ach_transfer": {
                "amount": 100,
                "originator_company_name": "BIG BANK",
                "originator_company_descriptive_date": null,
                "originator_company_discretionary_data": null,
                "originator_company_entry_description": "RESERVE",
                "originator_company_id": "0987654321",
                "receiver_id_number": "12345678900",
                "receiver_name": "IAN CREASE",
                "trace_number": "021000038461022"
              }
            },
            "type": "transaction"
          }
        }
      J
    end
    let(:expected_old_data) { old_body["data"] }
    let(:expected_new_data) { new_body["data"] }
  end

  it_behaves_like "a replicator that deals with resources and wrapped events",
                  "increase_transaction_v1" do |_name|
    let(:resource_json) { resource_in_envelope_json.fetch("data") }
    let(:resource_in_envelope_json) do
      JSON.parse(<<~J)
        {
          "event_id": "transaction_event_123",
          "event": "created",
          "created_at": "2020-01-31T23:59:59Z",
          "data": {
            "account_id": "account_in71c4amph0vgo2qllky",
            "amount": 100,
            "currency": "USD",
            "created_at": "2020-01-31T23:59:59Z",
            "description": "Frederick S. Holmes",
            "id": "transaction_uyrp7fld2ium70oa7oi",
            "route_id": "account_number_v18nkfqm6afpsrvy82b2",
            "route_type": "account_number",
            "source": {
              "category": "inbound_ach_transfer",
              "inbound_ach_transfer": {
                "amount": 100,
                "originator_company_name": "BIG BANK",
                "originator_company_descriptive_date": null,
                "originator_company_discretionary_data": null,
                "originator_company_entry_description": "RESERVE",
                "originator_company_id": "0987654321",
                "receiver_id_number": "12345678900",
                "receiver_name": "IAN CREASE",
                "trace_number": "021000038461022"
              }
            },
            "type": "transaction"
          }
        }
      J
    end
  end

  it_behaves_like "a replicator that verifies backfill secrets" do
    let(:correct_creds_sint) do
      Webhookdb::Fixtures.service_integration.create(
        service_name: "increase_transaction_v1",
        backfill_key: "bfkey",
        api_url: "https://api.increase.com",
      )
    end
    let(:incorrect_creds_sint) do
      Webhookdb::Fixtures.service_integration.create(
        service_name: "increase_transaction_v1",
        backfill_key: "bfkey_wrong",
        api_url: "https://api.increase.com",
      )
    end

    let(:success_body) do
      <<~R
        {
          "data": [],
          "response_metadata": {}
        }
      R
    end

    def stub_service_request
      return stub_request(:get, "https://api.increase.com/transactions").
          with(headers: {"Authorization" => "Bearer bfkey"}).
          to_return(status: 200, body: success_body, headers: {})
    end

    def stub_service_request_401_error
      return stub_request(:get, "https://api.increase.com/transactions").
          with(headers: {"Authorization" => "Bearer bfkey_wrong"}).
          to_return(status: 401, body: "", headers: {})
    end

    def stub_service_request_error
      return stub_request(:get, "https://api.increase.com/transactions").
          with(headers: {"Authorization" => "Bearer bfkey_wrong"}).
          to_return(status: 401, body: "", headers: {})
    end
  end

  it_behaves_like "a replicator that can backfill", "increase_transaction_v1" do
    # We are specifying the :api_url value because it gets used in the backfill process
    let(:api_url) { "https://api.increase.com" }
    let(:page1_response) do
      <<~R
        {
          "data": [
            {
              "account_id": "account_in71c4amph0vgo2qllky",
              "amount": 100,
              "currency": "USD",
              "created_at": "2020-01-31T23:59:59Z",
              "description": "Frederick S. Holmes",
              "id": "transaction_uyrp7fld2ium70oa7oi",
              "route_id": "account_number_v18nkfqm6afpsrvy82b2",
              "route_type": "account_number",
              "source": {
                "category": "inbound_ach_transfer",
                "inbound_ach_transfer": {
                  "amount": 100,
                  "originator_company_name": "BIG BANK",
                  "originator_company_descriptive_date": null,
                  "originator_company_discretionary_data": null,
                  "originator_company_entry_description": "RESERVE",
                  "originator_company_id": "0987654321",
                  "receiver_id_number": "12345678900",
                  "receiver_name": "IAN CREASE",
                  "trace_number": "021000038461022"
                }
              },
              "type": "transaction"
            },
            {
              "account_id": "account_in71c4amph0vgo2qllky",
              "amount": 100,
              "currency": "USD",
              "created_at": "2020-01-31T23:59:59Z",
              "description": "Frederick S. Holmes",
              "id": "transaction_uyrp7fld2ium70oasdf",
              "route_id": "account_number_v18nkfqm6afpsrvy82b2",
              "route_type": "account_number",
              "source": {
                "category": "inbound_ach_transfer",
                "inbound_ach_transfer": {
                  "amount": 100,
                  "originator_company_name": "BIG BANK",
                  "originator_company_descriptive_date": null,
                  "originator_company_discretionary_data": null,
                  "originator_company_entry_description": "RESERVE",
                  "originator_company_id": "0987654321",
                  "receiver_id_number": "12345678900",
                  "receiver_name": "IAN CREASE",
                  "trace_number": "021000038461022"
                }
              },
              "type": "transaction"
            }
          ],
          "response_metadata": {
            "next_cursor": "aW1pdCI6Mn0sInBvc2l0aW9uIjp7Im9mZnNldCI6NH19"
          }
        }
      R
    end
    let(:page2_response) do
      <<~R
        {
          "data": [
            {
              "account_id": "account_in71c4amph0vgo2qllky",
              "amount": 100,
              "currency": "USD",
              "created_at": "2020-01-31T23:59:59Z",
              "description": "Frederick S. Holmes",
              "id": "transaction_uyrp7fld2ium70oqwer",
              "route_id": "account_number_v18nkfqm6afpsrvy82b2",
              "route_type": "account_number",
              "source": {
                "category": "inbound_ach_transfer",
                "inbound_ach_transfer": {
                  "amount": 100,
                  "originator_company_name": "BIG BANK",
                  "originator_company_descriptive_date": null,
                  "originator_company_discretionary_data": null,
                  "originator_company_entry_description": "RESERVE",
                  "originator_company_id": "0987654321",
                  "receiver_id_number": "12345678900",
                  "receiver_name": "IAN CREASE",
                  "trace_number": "021000038461022"
                }
              },
              "type": "transaction"
            },
            {
              "account_id": "account_in71c4amph0vgo2qllky",
              "amount": 100,
              "currency": "USD",
              "created_at": "2020-01-31T23:59:59Z",
              "description": "Frederick S. Holmes",
              "id": "transaction_uyrp7fld2ium70opoiu",
              "route_id": "account_number_v18nkfqm6afpsrvy82b2",
              "route_type": "account_number",
              "source": {
                "category": "inbound_ach_transfer",
                "inbound_ach_transfer": {
                  "amount": 100,
                  "originator_company_name": "BIG BANK",
                  "originator_company_descriptive_date": null,
                  "originator_company_discretionary_data": null,
                  "originator_company_entry_description": "RESERVE",
                  "originator_company_id": "0987654321",
                  "receiver_id_number": "12345678900",
                  "receiver_name": "IAN CREASE",
                  "trace_number": "021000038461022"
                }
              },
              "type": "transaction"
            }
          ],
          "response_metadata": {
            "next_cursor": "lpYUWlPako5ZlEiLCJsaW1pdCI6Mn0sInBvc2l0aW9uIjp7Im9mZnNldCI6Nn19"
          }
        }
      R
    end
    let(:page3_response) do
      <<~R
        {
          "data": [],
          "response_metadata": {
            "next_cursor": null
          }
        }
      R
    end
    let(:expected_items_count) { 4 }

    def stub_service_requests
      return [
        stub_request(:get, "https://api.increase.com/transactions").
            with(headers: {"Authorization" => "Bearer bfkey"}).
            to_return(status: 200, body: page1_response, headers: {"Content-Type" => "application/json"}),
        stub_request(:get, "https://api.increase.com/transactions?cursor=aW1pdCI6Mn0sInBvc2l0aW9uIjp7Im9mZnNldCI6NH19").
            to_return(status: 200, body: page2_response, headers: {"Content-Type" => "application/json"}),
        stub_request(:get, "https://api.increase.com/transactions?cursor=lpYUWlPako5ZlEiLCJsaW1pdCI6Mn0sInBvc2l0aW9uIjp7Im9mZnNldCI6Nn19").
            to_return(status: 200, body: page3_response, headers: {"Content-Type" => "application/json"}),
      ]
    end

    def stub_empty_requests
      return [
        stub_request(:get, "https://api.increase.com/transactions").
            to_return(status: 200, body: page3_response, headers: {"Content-Type" => "application/json"}),
      ]
    end

    def stub_service_request_error
      return stub_request(:get, "https://api.increase.com/transactions").
          to_return(status: 403, body: "gah")
    end
  end

  describe "webhook validation" do
    let(:sint) { Webhookdb::Fixtures.service_integration.create(service_name: "increase_transaction_v1") }
    let(:svc) { Webhookdb::Replicator.create(sint) }

    it "returns a 401 as per spec if there is no Authorization header" do
      req = fake_request
      status, _headers, _body = svc.webhook_response(req).to_rack
      expect(status).to eq(401)
    end

    it "returns a 401 for an invalid Authorization header" do
      sint.update(webhook_secret: "user:pass")
      req = fake_request(input: '{"data": "asdfghujkl"}')
      data = req.body
      computed_auth = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), "user:pass", '{"data": "foobar"}')
      req.add_header("HTTP_X_BANK_WEBHOOK_SIGNATURE", "sha256=" + computed_auth)
      status, _headers, body = svc.webhook_response(req).to_rack
      expect(status).to eq(401)
      expect(body).to include("invalid hmac")
    end

    it "returns a 202 with a valid Authorization header" do
      sint.update(webhook_secret: "user:pass")
      req = fake_request(input: '{"data": "asdfghujkl"}')
      data = req.body
      computed_auth = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), "user:pass", data)
      req.add_header("HTTP_X_BANK_WEBHOOK_SIGNATURE", "sha256=" + computed_auth)
      status, _headers, _body = svc.webhook_response(req).to_rack
      expect(status).to eq(202)
    end
  end

  describe "state machine calculation" do
    let(:sint) do
      # Set api url to empty string so that backfill flow works correctly for testing purposes
      Webhookdb::Fixtures.service_integration.create(service_name: "increase_transaction_v1", api_url: "")
    end
    let(:svc) { Webhookdb::Replicator.create(sint) }

    describe "calculate_webhook_state_machine" do
      it "asks for webhook secret" do
        sm = sint.replicator.calculate_webhook_state_machine
        expect(sm).to have_attributes(
          needs_input: true,
          prompt: "Paste or type your secret here:",
          prompt_is_secret: true,
          post_to_url: end_with("/service_integrations/#{sint.opaque_id}/transition/webhook_secret"),
          complete: false,
          output: match("We've made an endpoint available for Increase Transaction webhooks:"),
        )
      end

      it "confirms reciept of webhook secret, returns org database info" do
        sint.webhook_secret = "whsec_abcasdf"
        sm = sint.replicator.calculate_webhook_state_machine
        expect(sm).to have_attributes(
          needs_input: false,
          prompt: "",
          prompt_is_secret: false,
          post_to_url: "",
          complete: true,
          output: match("Great! WebhookDB is now listening for Increase Transaction webhooks."),
        )
      end
    end

    describe "calculate_backfill_state_machine" do
      let(:success_body) do
        <<~R
          {
            "data": [],
            "response_metadata": {}
          }
        R
      end

      def stub_service_request
        return stub_request(:get, "https://api.increase.com/transactions").
            with(headers: {"Authorization" => "Bearer bfkey"}).
            to_return(status: 200, body: success_body, headers: {})
      end

      it "asks for backfill key" do
        sm = sint.replicator.calculate_backfill_state_machine
        expect(sm).to have_attributes(
          needs_input: true,
          prompt: "Paste or type your API Key here:",
          prompt_is_secret: true,
          post_to_url: end_with("/service_integrations/#{sint.opaque_id}/transition/backfill_key"),
          complete: false,
          output: match("In order to backfill Increase Transactions, we need an API key."),
        )
      end

      it "asks for api url" do
        sint.backfill_key = "bfkey"
        sm = sint.replicator.calculate_backfill_state_machine
        expect(sm).to have_attributes(
          needs_input: true,
          prompt: "Paste or type your API url here:",
          prompt_is_secret: false,
          post_to_url: end_with("/service_integrations/#{sint.opaque_id}/transition/api_url"),
          complete: false,
          output: match("Now we want to make sure we're sending API requests to the right place"),
        )
      end

      it "confirms reciept of api url, returns org database info" do
        sint.backfill_key = "bfkey"
        sint.api_url = "https://api.increase.com"
        res = stub_service_request
        sm = sint.replicator.calculate_backfill_state_machine
        expect(res).to have_been_made
        expect(sm).to have_attributes(
          needs_input: false,
          prompt: "",
          prompt_is_secret: false,
          post_to_url: "",
          complete: true,
          output: match("Great! We are going to start backfilling your Increase Transactions."),
        )
      end
    end
  end

  it_behaves_like "a replicator that upserts webhooks only under specific conditions",
                  "increase_transaction_v1" do
    let(:incorrect_webhook) do
      JSON.parse(<<~J)
        {
          "event_id": "transfer_event_123",
          "event": "created",
          "created_at": "2020-01-31T23:59:59Z",
          "data": {
            "account_number": "987654321",
            "account_id": "account_566f1f672175",
            "amount": 100,
            "approval": {
              "approved_at": "2020-01-31T23:59:59Z",
              "approved_by": "user@example.com"
            },
            "cancellation": {},
            "created_at": "2020-01-31T23:59:59Z",
            "id": "ach_transfer_uoxatyh3lt5evrsdvo7q",
            "network": "ach",
            "path": "/transfers/achs/ach_transfer_uoxatyh3lt5evrsdvo7q",
            "return": {},
            "routing_number": "123456789",
            "statement_descriptor": "Statement descriptor",
            "status": "returned",
            "submission": {},
            "template_id": "ach_transfer_template_wofoi8uhkjzi5rubh3kt",
            "transaction_id": "transaction_uyrp7fld2ium70oa7oi",
            "addendum": null,
            "notification_of_change": null
          }
        }
      J
    end
  end
end
