# frozen_string_literal: true

require "webhookdb/postgres/model"

require "webhookdb/webhook_subscription"

# Represents the attempted delivery of a rowupsert to a particular webhook subscription.
# See WebhookSubscription for more details.
class Webhookdb::WebhookSubscription::Delivery < Webhookdb::Postgres::Model(:webhook_subscription_deliveries)
  plugin :timestamps

  many_to_one :webhook_subscription, class: "Webhookdb::WebhookSubscription"

  # See WebhookSubhscription#attempt_delivery
  def attempt_delivery
    self.webhook_subscription.attempt_delivery(self)
  end

  # Add an attempt to this instance.
  def add_attempt(status:, at: Time.now)
    self.attempt_timestamps << at
    self.modified!(:attempt_timestamps)
    self.attempt_http_response_statuses << status
    self.modified!(:attempt_http_response_statuses)
  end

  # Create a list of Attempt instances.
  def attempts
    return self.attempt_timestamps.
        zip(self.attempt_http_response_statuses).
        map { |(at, status)| Attempt.new(at, status) }
  end

  # Fast path for getting the total attempt count.
  def attempt_count
    return self.attempt_timestamps.length
  end

  # Return the latest attempt, or nil if there have been no attempts.
  def latest_attempt
    cnt = self.attempt_count
    return nil if cnt.zero?
    ts = self.attempt_timestamps[cnt - 1]
    status = self.attempt_http_response_statuses[cnt - 1]
    return Attempt.new(ts, status)
  end

  # One of 'pending' (no attempts), 'success', or 'error'.
  def latest_attempt_status
    att = self.latest_attempt
    return "pending" if att.nil?
    return att.success ? "success" : "error"
  end

  class Attempt
    attr_reader :at, :status, :success

    def initialize(at, status)
      @at = at
      @status = status
      @success = status < 300
    end
  end
end

# Table: webhook_subscription_deliveries
# ------------------------------------------------------------------------------------------------------------------------------
# Columns:
#  id                             | integer                    | PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY
#  created_at                     | timestamp with time zone   | NOT NULL DEFAULT now()
#  attempt_timestamps             | timestamp with time zone[] | NOT NULL DEFAULT ARRAY[]::timestamp with time zone[]
#  attempt_http_response_statuses | smallint[]                 | NOT NULL DEFAULT ARRAY[]::smallint[]
#  payload                        | jsonb                      | NOT NULL
#  webhook_subscription_id        | integer                    | NOT NULL
# Indexes:
#  webhook_subscription_deliveries_pkey                          | PRIMARY KEY btree (id)
#  webhook_subscription_deliveries_webhook_subscription_id_index | btree (webhook_subscription_id)
# Check constraints:
#  balanced_attempts | (array_length(attempt_timestamps, 1) = array_length(attempt_http_response_statuses, 1))
# Foreign key constraints:
#  webhook_subscription_deliveries_webhook_subscription_id_fkey | (webhook_subscription_id) REFERENCES webhook_subscriptions(id)
# ------------------------------------------------------------------------------------------------------------------------------
