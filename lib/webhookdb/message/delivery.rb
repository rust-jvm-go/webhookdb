# frozen_string_literal: true

require "webhookdb/postgres/model"

require "webhookdb/message"

class Webhookdb::Message::Delivery < Webhookdb::Postgres::Model(:message_deliveries)
  plugin :timestamps
  plugin :soft_deletes

  many_to_one :recipient, class: "Webhookdb::Customer"
  one_to_many :bodies, class: "Webhookdb::Message::Body"

  dataset_module do
    def unsent
      return self.not_soft_deleted.where(sent_at: nil)
    end

    def sent
      return self.not_soft_deleted.exclude(sent_at: nil)
    end

    def to_customers(customers)
      emails = customers.is_a?(Sequel::Dataset) ? customers.select(:email) : customers.map(&:email)
      return self.where(Sequel[to: emails] | Sequel[recipient: customers])
    end
  end

  def initialize(*)
    super
    self[:extra_fields] ||= {}
  end

  def body_with_mediatype(mt)
    return self.bodies.find { |b| b.mediatype == mt }
  end

  def body_with_mediatype!(mt)
    (b = self.body_with_mediatype(mt)) or raise "Delivery #{self.id} has no body with mediatype #{mt}"
    return b
  end

  def sent?
    return self.sent_at ? true : false
  end

  def send!
    return nil if self.sent? || self.soft_deleted?
    self.db.transaction do
      self.lock!
      return nil if self.sent? || self.soft_deleted?
      (transport_message_id = self.transport.send!(self)) or return nil
      self.update(transport_message_id:, sent_at: Time.now)
      return self
    end
  end

  def transport
    return Webhookdb::Message::Transport.for(self.transport_type)
  end

  def transport!
    return Webhookdb::Message::Transport.for!(self.transport_type)
  end

  def self.preview(template_class_name, transport: :email, rack_env: Webhookdb::RACK_ENV, commit: false)
    raise "Can only preview in development" unless rack_env == "development"

    pattern = File.join(Pathname(__FILE__).dirname.parent, "messages", "*.rb")
    Gem.find_files(pattern).each do |path|
      require path
    end

    begin
      template_class = "Webhookdb::Messages::#{template_class_name}".constantize
    rescue NameError
      raise Webhookdb::Message::MissingTemplateError, "Webhookdb::Messages::#{template_class_name} not found"
    end

    require "webhookdb/fixtures"
    Webhookdb::Fixtures.load_all

    delivery = nil
    self.db.transaction(rollback: commit ? nil : :always) do
      to = Webhookdb::Fixtures.customer.create
      template = template_class.fixtured(to)
      delivery = template.dispatch(to, transport:)
      delivery.bodies # Fetch this ahead of time so it is there after rollback
    end
    return delivery
  end
end

# Table: message_deliveries
# ---------------------------------------------------------------------------------------------------------------------
# Columns:
#  id                   | integer                  | PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY
#  created_at           | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at           | timestamp with time zone |
#  template             | text                     | NOT NULL
#  transport_type       | text                     | NOT NULL
#  transport_service    | text                     | NOT NULL
#  transport_message_id | text                     |
#  sent_at              | timestamp with time zone |
#  to                   | text                     | NOT NULL
#  recipient_id         | integer                  |
#  extra_fields         | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  soft_deleted_at      | timestamp with time zone |
# Indexes:
#  message_deliveries_pkey                     | PRIMARY KEY btree (id)
#  message_deliveries_transport_message_id_key | UNIQUE btree (transport_message_id)
#  message_deliveries_recipient_id_index       | btree (recipient_id)
#  message_deliveries_sent_at_index            | btree (sent_at)
# Foreign key constraints:
#  message_deliveries_recipient_id_fkey | (recipient_id) REFERENCES customers(id) ON DELETE SET NULL
# Referenced By:
#  message_bodies | message_bodies_delivery_id_fkey | (delivery_id) REFERENCES message_deliveries(id) ON DELETE CASCADE
# ---------------------------------------------------------------------------------------------------------------------
