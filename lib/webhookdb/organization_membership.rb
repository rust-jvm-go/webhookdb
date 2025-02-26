# frozen_string_literal: true

require "webhookdb/postgres/model"

class Webhookdb::OrganizationMembership < Webhookdb::Postgres::Model(:organization_memberships)
  VALID_ROLE_NAMES = ["admin", "member"].freeze

  many_to_one :organization, class: "Webhookdb::Organization"
  many_to_one :customer, class: "Webhookdb::Customer"
  many_to_one :membership_role, class: "Webhookdb::Role"

  def verified?
    return self.verified
  end

  def default?
    return self.is_default
  end

  def customer_email
    return self.customer.email
  end

  def organization_name
    return self.organization.name
  end

  def status
    return "invited" unless self.verified
    self.membership_role.name
  end

  def admin?
    return self.membership_role.name == "admin"
  end
end

# Table: organization_memberships
# ------------------------------------------------------------------------------------------------------------------------------
# Columns:
#  id                 | integer | PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY
#  customer_id        | integer | NOT NULL
#  organization_id    | integer | NOT NULL
#  verified           | boolean | NOT NULL
#  invitation_code    | text    | NOT NULL DEFAULT ''::text
#  membership_role_id | integer | NOT NULL
#  is_default         | boolean | NOT NULL DEFAULT false
# Indexes:
#  organization_memberships_pkey | PRIMARY KEY btree (id)
#  one_default_per_customer      | UNIQUE btree (customer_id, organization_id) WHERE is_default IS TRUE
# Check constraints:
#  default_is_verified | (is_default IS TRUE AND verified IS TRUE OR is_default IS FALSE)
#  invited_has_code    | (verified IS TRUE AND length(invitation_code) < 1 OR verified IS FALSE AND length(invitation_code) > 0)
# Foreign key constraints:
#  organization_memberships_customer_id_fkey        | (customer_id) REFERENCES customers(id)
#  organization_memberships_membership_role_id_fkey | (membership_role_id) REFERENCES roles(id)
#  organization_memberships_organization_id_fkey    | (organization_id) REFERENCES organizations(id)
# ------------------------------------------------------------------------------------------------------------------------------
