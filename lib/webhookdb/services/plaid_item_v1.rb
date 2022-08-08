# frozen_string_literal: true

require "webhookdb/plaid"

class Webhookdb::Services::PlaidItemV1 < Webhookdb::Services::Base
  include Appydays::Loggable

  # If the Plaid request fails for one of these errors,
  # rather than error, we store the response as in the 'error' field
  # since the issue is not on our end.
  STORABLE_ERROR_TYPES = [
    "INVALID_INPUT",
    "ITEM_ERROR",
  ].to_set

  # @return [Webhookdb::Services::Descriptor]
  def self.descriptor
    return Webhookdb::Services::Descriptor.new(
      name: "plaid_item_v1",
      ctor: self,
      feature_roles: ["beta"],
      resource_name_singular: "Plaid Item",
    )
  end

  def _remote_key_column
    return Webhookdb::Services::Column.new(:plaid_id, TEXT)
  end

  def _denormalized_columns
    return [
      Webhookdb::Services::Column.new(:institution_id, TEXT, index: true),
      Webhookdb::Services::Column.new(:encrypted_access_token, TEXT),
      Webhookdb::Services::Column.new(:row_created_at, TIMESTAMP, index: true),
      Webhookdb::Services::Column.new(:consent_expiration_time, TIMESTAMP),
      Webhookdb::Services::Column.new(:update_type, TEXT),
      Webhookdb::Services::Column.new(:error, OBJECT),
      Webhookdb::Services::Column.new(:available_products, OBJECT),
      Webhookdb::Services::Column.new(:billed_products, OBJECT),
      Webhookdb::Services::Column.new(:status, OBJECT),
      Webhookdb::Services::Column.new(:row_updated_at, TIMESTAMP, index: true),
      Webhookdb::Services::Column.new(:transaction_sync_next_cursor, TEXT),
    ]
  end

  def _timestamp_column_name
    return :row_updated_at
  end

  def _update_where_expr
    return self.qualified_table_sequel_identifier[:row_updated_at] < Sequel[:excluded][:row_updated_at]
  end

  def upsert_has_deps?
    return true
  end

  def upsert_webhook(body:)
    if body.fetch("webhook_type") != "ITEM"
      self.service_integration.dependents.each do |d|
        d.service_instance.upsert_webhook(body:)
      end
      return
    end
    now = Time.now
    # Webhooks are going to be from plaid, or from the client,
    # so the 'codes' here cover more than just Plaid.
    payload = {
      row_created_at: now,
      row_updated_at: now,
      data: {"item_id" => body.fetch("item_id")}.to_json,
      plaid_id: body.fetch("item_id"),
    }
    case body.fetch("webhook_code")
      when "ERROR", "USER_PERMISSION_REVOKED"
        payload[:error] = body.fetch("error").to_json
      when "PENDING_EXPIRATION"
        payload[:consent_expiration_time] = body.fetch("consent_expiration_time")
      when "CREATED"
        payload.merge!(self._handle_item_create(body.fetch("item_id"), body.fetch("access_token")))
      when "UPDATED"
        payload.merge!(self._handle_item_refresh(body.fetch("item_id")))
      else
        return nil
    end
    update = self._coalesce_excluded_on_update(payload, [:row_created_at])
    upserted_rows = self.admin_dataset(timeout: :fast) do |ds|
      ds.insert_conflict(
        target: self._remote_key_column.name,
        update:,
      ).insert(payload)
    end
    row_changed = upserted_rows.present?
    self._notify_dependents(payload, row_changed)
    return unless row_changed
    self._publish_rowupsert(payload)
  end

  def _handle_item_create(_item_id, access_token)
    encrypted_access_token = Webhookdb::Crypto.encrypt_value(
      Webhookdb::Crypto::Boxed.from_b64(self.service_integration.data_encryption_secret),
      Webhookdb::Crypto::Boxed.from_raw(access_token),
    ).base64
    payload = self._fetch_insert_payload(access_token)
    payload[:encrypted_access_token] = encrypted_access_token
    return payload
  end

  def _handle_item_refresh(item_id)
    plaid_item_row = self.readonly_dataset(timeout: :fast) { |ds| ds[plaid_id: item_id] }
    if plaid_item_row.nil?
      raise Webhookdb::InvalidPrecondition,
            "could not find Plaid item #{item_id} for integration #{self.service_integration.opaque_id}"
    end
    access_token = self.decrypt_item_row_access_token(plaid_item_row)
    return self._fetch_insert_payload(access_token)
  end

  def _fetch_insert_payload(access_token)
    begin
      resp = Webhookdb::Http.post(
        "#{self.service_integration.api_url}/item/get",
        {
          access_token:,
          client_id: self.service_integration.backfill_key,
          secret: self.service_integration.backfill_secret,
        },
        logger: self.logger,
      )
    rescue Webhookdb::Http::Error => e
      errtype = e.response.parsed_response["error_type"]
      if STORABLE_ERROR_TYPES.include?(errtype)
        return {
          error: e.response.body,
        }
      end
      raise e
    end
    body = resp.parsed_response
    return {
      available_products: self._nil_or_json(body.fetch("item").fetch("available_products")),
      billed_products: self._nil_or_json(body.fetch("item").fetch("billed_products")),
      error: self._nil_or_json(body.fetch("item").fetch("error")),
      institution_id: body.fetch("item").fetch("institution_id"),
      update_type: body.fetch("item").fetch("update_type"),
      consent_expiration_time: body.fetch("item").fetch("consent_expiration_time"),
      status: self._nil_or_json(body.fetch("status")),
    }
  end

  def decrypt_item_row_access_token(plaid_item_row)
    return Webhookdb::Crypto.decrypt_value(
      Webhookdb::Crypto::Boxed.from_b64(self.service_integration.data_encryption_secret),
      Webhookdb::Crypto::Boxed.from_b64(plaid_item_row.fetch(:encrypted_access_token)),
    ).raw
  end

  def _webhook_response(request)
    return Webhookdb::Plaid.webhook_response(request, self.service_integration.webhook_secret)
  end

  def process_state_change(field, value)
    if field == "api_url"
      value = "https://production.plaid.com" if value.blank? || value.downcase.include?("production")
      value = "https://sandbox.plaid.com" if value.downcase.include?("sandbox")
      value = "https://development.plaid.com" if value.downcase.include?("development")
    end
    super(field, value)
  end

  def calculate_create_state_machine
    step = Webhookdb::Services::StateMachineStep.new
    if self.service_integration.webhook_secret.blank?
      self.service_integration.data_encryption_secret ||= Webhookdb::Crypto.encryption_key.base64
      self.service_integration.save_changes
      step.output = %(You are about to add support for adding Plaid Items (access tokens)
into WebhookDB, which is necessary for other Plaid integrations (such as Transactions) to work.

We have detailed instructions on this process
at https://webhookdb.com/docs/plaid.

The first step is to generate a secret you will use for signing
API requests back to WebhookDB. You can use '#{Webhookdb::Id.rand_enc(16)}'
or generate your own value.
Copy and paste or enter a new value, and press enter.)
      return step.secret_prompt("secret").webhook_secret(self.service_integration)
    end
    if self.service_integration.api_url.blank?
      step.output = %(Great. Now we want to make sure we're sending API requests to the right place.
Plaid uses 3 separate environments:

https://sandbox.plaid.com (Sandbox)
https://development.plaid.com (Development)
https://production.plaid.com (Production)

Leave the prompt blank or use 'production' for production,
or input 'development' or 'sandbox' (or input the URL).
      )
      return step.prompting("API host").api_url(self.service_integration)
    end
    if self.service_integration.backfill_key.blank?
      step.output = %(Almost there. We will need to use the Plaid API to fetch data
about Plaid Items and other resources, so we need your Client Id and Secret.)
      return step.prompting("Plaid Client ID").backfill_key(self.service_integration)
    end
    if self.service_integration.backfill_secret.blank?
      step.output = %(And now your API secret, too.)
      return step.secret_prompt("Plaid Secret").backfill_secret(self.service_integration)
    end
    step.output = %(Excellent. We have made a URL available
that you must use for webhooks, both in Plaid and from your backend:

#{self._webhook_endpoint}

The secret to use for signing is:

#{self.service_integration.webhook_secret}

At this point, you are ready to follow the detailed instructions
found here: https://webhookdb.com/docs/plaid.

#{self._query_help_output})
    return step.completed
  end

  def calculate_backfill_state_machine
    return self.calculate_create_state_machine
  end
end
