# frozen_string_literal: true

require "grape"

require "webhookdb/api"
require "webhookdb/admin_api"

class Webhookdb::API::Organizations < Webhookdb::API::V1
  resource :organizations do
    desc "Return all organizations associated with customer"
    params do
      requires :customer_id, type: String
    end
    get do
      fields = params
      customer = Webhookdb::Customer[fields[:customer_id]]
      data = customer.organizations
      present data, with: Webhookdb::AdminAPI::OrganizationEntity
    end
  end
end