# frozen_string_literal: true

class Webhookdb::Subscription < Webhookdb::Postgres::Model(:subscriptions)
  extend Webhookdb::MethodUtilities
  include Appydays::Configurable
  include Appydays::Loggable

  plugin :timestamps
  plugin :soft_deletes

  configurable(:subscriptions) do
    setting :max_free_integrations, 2
  end

  def initialize(*)
    super
    self[:stripe_json] ||= Sequel.pg_json({})
  end

  def status
    return self.stripe_json["status"]
  end

  def self.create_or_update_from_webhook(request_params)
    data = request_params["data"]["object"]
    self.db.transaction do
      sub = self.find_or_create_or_find(stripe_id: data["id"])
      sub.update(stripe_json: data.to_json, stripe_customer_id: data["customer"])
      sub.save_changes
      return sub
    end
  end

  def self.status_for_org(org)
    used = org.service_integrations.count
    data = {
      org_name: org.name,
      billing_email: org.billing_email,
      integrations_used: used.to_s,
    }
    subscription = Webhookdb::Subscription[stripe_customer_id: org.stripe_customer_id]
    if subscription.nil?
      data[:plan_name] = "Free"
      data[:integrations_left] = [0, Webhookdb::Subscription.max_free_integrations - used].max.to_s
      data[:sub_status] = ""
    else
      data[:plan_name] = "Premium"
      data[:integrations_left] = "unlimited"
      data[:sub_status] = subscription.status
    end
    return data
  end
end
