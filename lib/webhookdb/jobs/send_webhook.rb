# frozen_string_literal: true

require "webhookdb/async/job"

class Webhookdb::Jobs::SendWebhook
  extend Webhookdb::Async::Job

  on "webhookdb.serviceintegration.rowupsert"

  def _perform(event)
    sint = self.lookup_model(Webhookdb::ServiceIntegration, event)
    self.add_log_tags(
      service_integration_id: sint.id,
      service_integration_name: sint.service_name,
      service_integration_table: sint.table_name,
    )
    sint.all_webhook_subscriptions_dataset.active.each do |sub|
      payload = {service_name: sint.service_name, table_name: sint.table_name, **event.payload[1]}
      sub.enqueue_delivery(payload)
    end
  end
end
