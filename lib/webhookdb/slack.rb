# frozen_string_literal: true

require "appydays/configurable"
require "slack-notifier"

require "webhookdb"

class Webhookdb::Slack
  include Appydays::Configurable
  extend Webhookdb::MethodUtilities

  # Set this during testing
  singleton_attr_accessor :http_client
  @http_client = nil

  configurable(:slack) do
    setting :webhook_url, "slack-webhook"
    setting :channel_override, nil
    setting :suppress_all, false
  end

  def self.new_notifier(opts={})
    opts[:channel] ||= "#eng-naboo"
    opts[:username] ||= "Unknown Webhook"
    opts[:icon_emoji] ||= ":question:"
    opts[:channel] = self.channel_override if self.channel_override
    return ::Slack::Notifier.new self.webhook_url do
      defaults opts
      if Webhookdb::Slack.suppress_all
        http_client NoOpHttpClient.new
      elsif Webhookdb::Slack.http_client
        http_client Webhookdb::Slack.http_client
      end
    end
  end

  def self.ignore_channel_not_found
    yield()
  rescue ::Slack::Notifier::APIError => e
    return if /channel_not_found/.match?(e.message)
    return if /channel_is_archived/.match?(e.message)
    raise e
  end

  def self.post_many(channels, notifier_options: {}, payload: {})
    channels.each do |chan|
      notifier = self.new_notifier(notifier_options.merge(channel: chan))
      self.ignore_channel_not_found do
        notifier.post(payload)
      end
    end
  end

  class NoOpHttpClient
    attr_reader :posts

    def initialize
      @posts = []
    end

    def post(uri, params={})
      self.posts << [uri, params]
    end
  end
end
