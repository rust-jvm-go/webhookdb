# frozen_string_literal: true

require "webhookdb/async/job"
require "webhookdb/jobs"

class Webhookdb::Jobs::IcalendarSync
  extend Webhookdb::Async::Job

  sidekiq_options retry: false

  def perform(sint_id, calendar_external_id)
    sint = self.lookup_model(Webhookdb::ServiceIntegration, sint_id)
    self.with_log_tags(sint.log_tags.merge(calendar_external_id:)) do
      row = sint.replicator.admin_dataset { |ds| ds[external_id: calendar_external_id] }
      if row.nil?
        self.logger.warn("icalendar_sync_row_miss", calendar_external_id:)
        return
      end
      self.logger.info("icalendar_sync_start")
      sint.replicator.sync_row(row)
    end
  end
end
