# frozen_string_literal: true

require "webhookdb/services/bookingpal_v1_mixin"

class Webhookdb::Services::BookingpalListingPolicyV1 < Webhookdb::Services::Base
  include Appydays::Loggable
  include Webhookdb::Services::BookingpalV1Mixin

  # @return [Webhookdb::Services::Descriptor]
  def self.descriptor
    return Webhookdb::Services::Descriptor.new(
      name: "bookingpal_listing_policy_v1",
      ctor: ->(sint) { Webhookdb::Services::BookingpalListingPolicyV1.new(sint) },
      feature_roles: [],
      resource_name_singular: "BookingPal Listing Policy",
      resource_name_plural: "BookingPal Listing Policies",
      dependency_descriptor: Webhookdb::Services::BookingpalListingV1.descriptor,
    )
  end

  def _remote_key_column
    return Webhookdb::Services::Column.new(
      :listing_id,
      INTEGER,
      data_key: "path",
      from_enrichment: true,
      converter: Webhookdb::Services::Column.converter_from_regex(%r{/v2/listing_policies/(\d+)}, coerce: :to_i),
    )
  end

  def _denormalized_columns
    return [
      Webhookdb::Services::Column.new(:row_updated_at, TIMESTAMP, defaulter: :now, optional: true),
    ]
  end

  def _fetch_enrichment(_resource, _event, request)
    return request.as_json
  end

  def synchronous_processing_response_body(request:, **)
    return request.body.to_json
  end
end
