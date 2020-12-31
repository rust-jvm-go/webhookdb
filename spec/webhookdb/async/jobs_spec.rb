# frozen_string_literal: true

require "webhookdb/async"
require "webhookdb/messages/specs"
require "rspec/eventually"

RSpec.describe "webhookdb async jobs", :async, :db, :do_not_defer_events, :no_transaction_check do
  before(:all) do
    Webhookdb::Async.require_jobs
  end

  describe "MessageDispatched", messaging: true do
    it "sends the delivery on create" do
      email = "wibble@lithic.tech"

      expect do
        Webhookdb::Messages::Testers::Basic.new.dispatch(email)
      end.to perform_async_job(Webhookdb::Async::MessageDispatched)

      expect(Webhookdb::Message::Delivery).to have_row(to: email).
        with_attributes(transport_message_id: be_a(String))
    end
  end

  describe "ResetCodeCreateDispatch" do
    it "sends an sms for an sms reset code" do
      customer = Webhookdb::Fixtures.customer(phone: "12223334444").create
      expect do
        customer.add_reset_code(token: "12345", transport: "sms")
      end.to perform_async_job(Webhookdb::Async::ResetCodeCreateDispatch)

      expect(Webhookdb::Message::Delivery.all).to contain_exactly(
        have_attributes(
          template: "verification",
          transport_type: "sms",
          to: "12223334444",
          bodies: contain_exactly(
            have_attributes(content: "Your Webhookdb verification code is: 12345"),
          ),
        ),
      )
    end

    it "sends an email for an email reset code" do
      customer = Webhookdb::Fixtures.customer(email: "maryjane@lithic.tech").create
      expect do
        customer.add_reset_code(token: "12345", transport: "email")
      end.to perform_async_job(Webhookdb::Async::ResetCodeCreateDispatch)

      expect(Webhookdb::Message::Delivery.all).to contain_exactly(
        have_attributes(
          template: "verification",
          transport_type: "email",
          to: "maryjane@lithic.tech",
          bodies: include(
            have_attributes(content: match(/12345/)),
          ),
        ),
      )
    end
  end

  describe "CreateMirrorTable" do
    it "creates the table for the service integration" do
      sint = nil
      expect do
        sint = Webhookdb::Fixtures.service_integration.create
      end.to perform_async_job(Webhookdb::Async::CreateMirrorTable)

      expect(sint).to_not be_nil
      expect(Webhookdb::Customer.db.table_exists?(sint&.table_name)).to be_truthy
    end
  end

  describe "ProcessWebhook" do
    it "passes the payload off to the processor" do
      sint = Webhookdb::Fixtures.service_integration.create
      expect(Webhookdb::Processor).to receive(:process).with(be === sint, headers: {"X-A" => "b"}, body: {"foo" => 1})
      expect do
        Webhookdb.publish(
          "webhookdb.serviceintegration.webhook",
          sint.id,
          {headers: {"X-A" => "b"}, body: {"foo" => 1}},
        )
      end.to perform_async_job(Webhookdb::Async::ProcessWebhook)
    end
  end
end
