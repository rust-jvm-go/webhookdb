# frozen_string_literal: true

require "webhookdb/connection_cache"

class Webhookdb::Services::Base
  # @return [Webhookdb::ServiceIntegration]
  attr_reader :service_integration

  def initialize(service_integration)
    @service_integration = service_integration
  end

  def table_sym
    return self.service_integration.table_name.to_sym
  end

  # Return a [status, headers, body] triple of the response for the webhook.
  # By default, if the webhook is not verified, we return a 401, otherwise we return success.
  # If the webhook needs extra validation or behavior (like Twilio requires special headers),
  # you can override this entirely and not bother overriding `_webhook_verified?`.
  def webhook_response(request)
    return [202, {"Content-Type" => "text/plain"}, "ok"] if self._webhook_verified?(request)
    return [401, {"Content-Type" => "text/plain"}, ""]
  end

  # Set the new service integration field and
  # return the newly calculated state machine.
  # @return [Webhookdb::Services::StateMachineStep]
  def process_state_change(field, value)
    self.db.transaction do
      self.service_integration.send("#{field}=", value)
      self.service_integration.save_changes
    end
  end

  # @return [Webhookdb::Services::StateMachineStep]
  def calculate_create_state_machine(organization)
    # This is a pure function that can be tested on its own--the endpoints just need to return a state machine step
    raise NotImplementedError
  end

  # @return [Webhookdb::Services::StateMachineStep]
  def calculate_backfill_state_machine(organization)
    # This is a pure function that can be tested on its own--the endpoints just need to return a state machine step
    raise NotImplementedError
  end

  # Check if the webhook is verified using the http request.
  # We must do this immediately in the endpoint itself,
  # since verification may include info specific to the request content
  # (like, it can be whitespace sensitive).
  #
  # @return [Boolean] if the webhook is verified.
  def _webhook_verified?(request)
    raise NotImplementedError
  end

  def create_table
    cmd = self._create_table_sql
    self.admin_dataset do |ds|
      ds.db << cmd
    end
  end

  def _create_table_sql
    tbl = self.service_integration.table_name
    remote_key_col = self._remote_key_column
    denormalized_columns = self._denormalized_columns
    lines = [
      "CREATE TABLE #{tbl} (",
      "  pk bigserial PRIMARY KEY,",
      "  data jsonb NOT NULL,",
      "  \"#{remote_key_col.name}\" #{remote_key_col.type} UNIQUE NOT NULL",
    ]
    denormalized_columns.each do |col|
      lines << ",  \"#{col.name}\" #{col.type} #{col.modifiers}"
    end
    lines << ");"
    denormalized_columns.each do |col|
      lines << "CREATE INDEX IF NOT EXISTS #{col.name}_idx ON #{tbl} (\"#{col.name}\");"
    end
    return lines.join("\n")
  end

  # Each integration needs a single remote key, like the Shopify order id for shopify orders,
  # or sid for Twilio resources. This column must be unique for the table.
  #
  # @abstract
  # @return [Webhookdb::Services::Column]
  def _remote_key_column
    raise NotImplementedError
  end

  # When an integration needs denormalized columns, specify them here.
  # Indices are created for each column.
  # Modifiers can be used if columns should have a default or whatever.
  #
  # @return [Array<Webhookdb::Services::Column]
  def _denormalized_columns
    return []
  end

  def upsert_webhook(body:)
    remote_key_col = self._remote_key_column
    inserting = {data: body.to_json}
    inserting.merge!(self._prepare_for_insert(body))
    self.admin_dataset do |ds|
      ds.insert_conflict(
        target: remote_key_col.name,
        update: inserting,
        update_where: self._update_where_expr,
      ).insert(inserting)
    end
  end

  # Upsert a backfill payload into the database.
  # By default, assume the webhook and backfill payload are the same shape
  # and just use upsert_webhook(body: payload).
  def upsert_backfill_payload(payload)
    self.upsert_webhook(body: payload)
  end

  # The argument for insert_conflict update_where clause.
  # Used to conditionally update, like updating only if a row is newer than what's stored.
  def _update_where_expr
    return nil
  end

  # Given the webhook headers and body, return a hash of what will be inserted.
  # It must include the key column and all denormalized columns.
  # TODO: Verify this and error if it's not the case when upserting
  #
  # @abstract
  # @return [Hash]
  def _prepare_for_insert(body)
    raise NotImplementedError
  end

  def admin_dataset(&block)
    self.with_dataset(self.service_integration.organization.admin_connection_url, &block)
  end

  def readonly_dataset(&block)
    self.with_dataset(self.service_integration.organization.readonly_connection_url, &block)
  end

  protected def with_dataset(url, &block)
    raise LocalJumpError if block.nil?
    Webhookdb::ConnectionCache.borrow(url) do |conn|
      yield(conn[self.table_sym])
    end
  end

  # In order to backfill, we need to:
  # - Iterate through pages of records from the external service
  # - Upsert each record
  # The caveats/complexities are:
  # - The backfill method should take care of retrying fetches for failed pages.
  # - That means it needs to keep track of some pagination token.
  def backfill
    raise Webhookdb::Services::CredentialsMissing if
      self.service_integration.backfill_key.blank? && self.service_integration.backfill_secret.blank?
    pagination_token = nil
    loop do
      page, next_pagination_token = self._fetch_backfill_page_with_retry(pagination_token)
      pagination_token = next_pagination_token
      page.each do |item|
        self.upsert_webhook(body: item)
      end
      break if pagination_token.blank?
    end
  end

  def max_backfill_retry_attempts
    return 3
  end

  def wait_for_retry_attempt(attempt:)
    return sleep(attempt)
  end

  def _fetch_backfill_page_with_retry(pagination_token, attempt: 1)
    return self._fetch_backfill_page(pagination_token)
  rescue RuntimeError => e
    raise e if attempt >= self.max_backfill_retry_attempts
    self.wait_for_retry_attempt(attempt: attempt)
    return self._fetch_backfill_page_with_retry(pagination_token, attempt: attempt + 1)
  end

  def _fetch_backfill_page(pagination_token)
    raise NotImplementedError
  end
end
