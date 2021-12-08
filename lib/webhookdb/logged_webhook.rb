# frozen_string_literal: true

require "webhookdb/postgres/model"

class Webhookdb::LoggedWebhook < Webhookdb::Postgres::Model(:logged_webhooks)
  many_to_one :organization, class: "Webhookdb::Organization"

  DELETE_UNOWNED = 14.days
  DELETE_SUCCESSES = 90.days
  TRUNCATE_SUCCESSES = 7.days
  DELETE_FAILURES = 90.days
  TRUNCATE_FAILURES = 30.days

  # Trim logged webhooks to keep this table to a reasonable size.
  # The current trim algorithm and rationale is:
  #
  # - Logs that belong to inserts that were not part of an org are for our internal use only.
  #   They usually indicate an integration that was misconfigured, or is for an org that doesn't exist.
  #   We keep these around for 2 weeks (they are always errors since they have no org).
  #   Ideally we investigate and remove them before that.
  #   We may need to 'block' certain opaque ids from being logged in the future,
  #   if for example we cannot get a client to turn off a misconfigured webhook.
  # - Successful webhooks get their contents (request body and headers)
  #   _truncated_ after 7 days (but the webhook row remains).
  #   Usually we don't need to worry about these so in theory we can avoid logging verbose info at all.
  # - Successful webhooks are deleted entirely after 90 days.
  #   Truncated webhooks are useful for statistics,
  #   but we can remove them earlier in the future.
  # - Failed webhooks get their contents truncated after 30 days,
  #   but the webhook row remains. We have a longer truncation date
  #   so we have more time to investigate.
  # - Error webhooks are deleted entirely after 90 days.
  def self.trim(now: Time.now)
    owned = self.exclude(organization_id: nil)
    unowned = self.where(organization_id: nil)
    successes = owned.where { response_status < 400 }
    failures = owned.where { response_status >= 400 }
    # Delete old unowned
    unowned.where { inserted_at < now - DELETE_UNOWNED }.delete
    # Delete successes first so they don't have to be truncated
    successes.where { inserted_at < now - DELETE_SUCCESSES }.delete
    self.truncate_dataset(successes.where { inserted_at < now - TRUNCATE_SUCCESSES })
    # Delete failures
    failures.where { inserted_at < now - DELETE_FAILURES }.delete
    self.truncate_dataset(failures.where { inserted_at < now - TRUNCATE_FAILURES })
  end

  # Send instances back in 'through the front door' of this API.
  # Return is a partition of [logs with 2xx responses, others].
  # Generally you can safely call `truncate_logs(result[0])`,
  # or pass in (truncate_successful: true).
  def self.retry_logs(instances, truncate_successful: false)
    successes, failures = instances.partition do |lw|
      uri = URI(Webhookdb.api_url + "/v1/service_integrations/#{lw.service_integration_opaque_id}")
      req = Net::HTTP::Post.new(uri.path)
      req.body = lw.request_body
      req.each_key.to_a.each { |k| req.delete(k) }
      lw.request_headers.each { |k, v| req[k] = v }
      # Delete the version key as it gets re-added automatically when we run this for real.
      # I am not sure why or if this is the right solution though.
      req.delete("Version")
      resp = Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.request(req)
      end
      resp.code.to_i < 400
    end
    self.truncate_logs(*successes) if truncate_successful
    return successes, failures
  end

  def retry_one(truncate_successful: false)
    _, bad = self.class.retry_logs([self], truncate_successful: truncate_successful)
    return bad.empty?
  end

  # Truncate the logs id'ed by the given instances.
  # Instances are NOT modified; you need to .refresh to see truncated values.
  def self.truncate_logs(*instances)
    ds = self.where(id: instances.map(&:id))
    return self.truncate_dataset(ds)
  end

  def self.truncate_dataset(ds)
    return ds.update(request_body: "", request_headers: "{}", truncated_at: Time.now)
  end

  def truncated?
    return self.truncated_at ? true : false
  end
end
