# frozen_string_literal: true

require "webhookdb/postgres/model"
require "sequel/plugins/soft_deletes"

class Webhookdb::ServiceIntegration < Webhookdb::Postgres::Model(:service_integrations)
  plugin :timestamps
  plugin :soft_deletes

  many_to_one :organization, class: "Webhookdb::Organization"

  def process_state_change(field, value)
    return Webhookdb::Services.service_instance(self).process_state_change(field, value)
  end

  def calculate_create_state_machine
    return Webhookdb::Services.service_instance(self).calculate_create_state_machine(self.organization)
  end

  def calculate_backfill_state_machine
    return Webhookdb::Services.service_instance(self).calculate_backfill_state_machine(self.organization)
  end

  def can_be_modified_by?(customer)
    return customer.verified_member_of?(self.organization)
  end

  # SUBSCRIPTION PERMISSIONS

  def plan_supports_integration?
    # if the sint's organization has an active subscription, return true
    return true if self.organization.active_subscription?
    # if there is no active subscription, check whether the integration is one of the first two
    # created by the organization
    limit = Webhookdb::Subscription.max_free_integrations
    free_integrations = Webhookdb::ServiceIntegration.
      where(organization: self.organization).order(:created_at).limit(limit).all
    free_integrations.each do |sint|
      return true if sint.id == self.id
    end
    # if not, the integration is not supported
    return false
  end

  # @!attribute table_name
  #   @return [String] Name of the table

  # @!attribute service_name
  #   @return [String] Lookup name of the service

  # @!attribute api_url
  #   @return [String] Root Url of the api to backfill from

  # @!attribute backfill_key
  #   @return [String] Key for backfilling.

  # @!attribute backfill_secret
  #   @return [String] Password/secret for backfilling.
end

# Table: service_integrations
# -------------------------------------------------------------------------------------------
# Columns:
#  id              | integer                  | PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY
#  created_at      | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at      | timestamp with time zone |
#  soft_deleted_at | timestamp with time zone |
#  organization_id | integer                  | NOT NULL
#  api_url         | text                     | NOT NULL DEFAULT ''::text
#  opaque_id       | text                     | NOT NULL
#  service_name    | text                     | NOT NULL
#  webhook_secret  | text                     | DEFAULT ''::text
#  table_name      | text                     | NOT NULL
#  backfill_key    | text                     | NOT NULL DEFAULT ''::text
#  backfill_secret | text                     | NOT NULL DEFAULT ''::text
# Indexes:
#  service_integrations_pkey          | PRIMARY KEY btree (id)
#  service_integrations_opaque_id_key | UNIQUE btree (opaque_id)
#  unique_tablename_in_org            | UNIQUE btree (organization_id, table_name)
# Foreign key constraints:
#  service_integrations_organization_id_fkey | (organization_id) REFERENCES organizations(id)
# -------------------------------------------------------------------------------------------
