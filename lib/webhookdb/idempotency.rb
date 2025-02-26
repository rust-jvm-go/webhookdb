# frozen_string_literal: true

require "webhookdb/postgres/model"

# Support idempotent operations.
# This is very useful when
# 1) protecting the API against requests dispatched multiple times,
# as browsers are liable to do, and
# 2) designing parts of a system so they can be used idempotently, especially async jobs.
# This ensures an event can be republished if a job fails, but jobs that worked won't be re-run.
#
# In general, you do not use Idempotency instances directly;
# instead, you will use once_ever and every.
# For example, to only send a welcome email once:
#
#   Webhookdb::Idempotency.once_ever.under_key("welcome-email-#{customer.id}") { send_welcome_email(customer) }
#
# Similarly, to prevent an action email from going out multiple times in a short period accidentally:
#
#   Webhookdb::Idempotency.every(1.hour).under_key("new-order-#{order.id}") { send_new_order_email(order) }
#
# Note that idempotency cannot be executed while already in a transaction.
# If it were, the unique row would not be visible to other transactions.
# So the new row must be committed, then the idempotency evaluated (and the callback potentially run).
# To disable this check, set 'Postgres.unsafe_skip_transaction_check' to true,
# usually using the :no_transaction_check spec metadata.
#
class Webhookdb::Idempotency < Webhookdb::Postgres::Model(:idempotencies)
  NOOP = :skipped

  class << self
    # Skip the transaction check. Useful in unit tests. See class docs for details.
    attr_accessor :skip_transaction_check

    def skip_transaction_check? = self.skip_transaction_check

    # @return [Builder]
    def once_ever
      b = self::Builder.new
      b._once_ever = true
      return b
    end

    # @return [Builder]
    def every(interval)
      b = self::Builder.new
      b._every = interval
      return b
    end

    def separate_connection
      @connection ||= Sequel.connect(
        uri,
        logger: self.logger,
        extensions: [
          :connection_validator,
          :pg_json, # Must have this to mirror the main model DB
        ],
        **Webhookdb::Dbutil.configured_connection_options,
      )
      return @connection
    end
  end

  class Builder
    attr_accessor :_every, :_once_ever, :_stored, :_sepconn, :_key

    # If set, the result of block is stored as JSON,
    # and returned when an idempotent call is made.
    # The JSON value (as_json) is returned from the block in all cases.
    # @return [Builder]
    def stored
      self._stored = true
      return self
    end

    # Run the idempotency on a separate connection.
    # Allows use of idempotency within an existing transaction block,
    # which is normally not allowed. Usually should be used with #stored,
    # since otherwise the result of the idempotency will be lost.
    #
    # NOTE: When calling code with using_seperate_connection,
    # you may want to use the spec metadata `truncate: Webhookdb::Idempotency`
    # since the row won't be covered by the spec's transaction.
    #
    # @return [Builder]
    def using_seperate_connection
      self._sepconn = true
      return self
    end

    # @return [Builder]
    def under_key(key, &block)
      self._key = key
      return self.execute(&block) if block
      return self
    end

    def execute
      if self._sepconn
        db = Webhookdb::Idempotency.separate_connection
      else
        db = Webhookdb::Idempotency.db
        Webhookdb::Postgres.check_transaction(
          db,
          "Cannot use idempotency while already in a transaction, since side effects may not be idempotent. " \
          "You can chain withusing_seperate_connection to run the idempotency itself separately.",
        )
      end

      db[:idempotencies].insert_conflict.insert(key: self._key)
      db.transaction do
        idem_row = db[:idempotencies].where(key: self._key).for_update.first
        if idem_row.fetch(:last_run).nil?
          result = yield()
          result = self._update_row(db, result)
          return result
        end
        noop_result = self._stored ? idem_row.fetch(:stored_result) : NOOP
        return noop_result if self._once_ever
        return noop_result if Time.now < (idem_row[:last_run] + self._every)
        result = yield()
        result = self._update_row(db, result)
        return result
      end
    end

    def _update_row(db, result)
      updates = {last_run: Time.now}
      if self._stored
        result = result.as_json
        updates[:stored_result] = Sequel.pg_jsonb_wrap(result)
      end
      db[:idempotencies].where(key: self._key).update(updates)
      return result
    end
  end
end

# Table: idempotencies
# -------------------------------------------------------------------------------------
# Columns:
#  id         | integer                  | PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY
#  created_at | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at | timestamp with time zone |
#  last_run   | timestamp with time zone |
#  key        | text                     |
# Indexes:
#  idempotencies_pkey    | PRIMARY KEY btree (id)
#  idempotencies_key_key | UNIQUE btree (key)
# -------------------------------------------------------------------------------------
