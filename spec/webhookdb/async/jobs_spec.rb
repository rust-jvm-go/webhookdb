# frozen_string_literal: true

require "amigo/durable_job"
require "webhookdb/async"
require "webhookdb/messages/specs"
require "rspec/eventually"

RSpec.describe "webhookdb async jobs", :async, :db, :do_not_defer_events, :no_transaction_check do
  before(:all) do
    Webhookdb::Async.setup_tests
    Sidekiq::Testing.inline!
  end

  describe "Backfill" do
    let(:page1_items) do
      [
        {"my_id" => "1", "at" => "Thu, 30 Jul 2015 21:12:33 +0000"},
        {"my_id" => "2", "at" => "Thu, 30 Jul 2015 21:12:33 +0000"},
      ]
    end

    it "starts backfill process" do
      sint = Webhookdb::Fixtures.service_integration.create(backfill_key: "bfkey", backfill_secret: "bfsek")
      sint.organization.prepare_database_connections
      req = Webhookdb::Replicator::Fake.stub_backfill_request(page1_items)
      Webhookdb::Replicator.create(sint).create_table
      bfjob = Webhookdb::Fixtures.backfill_job.for(sint).create
      expect do
        Amigo.publish("webhookdb.backfilljob.run", bfjob.id)
      end.to perform_async_job(Webhookdb::Jobs::Backfill)
      expect(req).to have_been_made
      Webhookdb::Replicator.create(sint).readonly_dataset do |ds|
        expect(ds.all).to have_length(2)
      end
      expect(bfjob.refresh).to be_finished
    ensure
      sint.organization.remove_related_database
    end

    it "noops if the job is finished" do
      sint = Webhookdb::Fixtures.service_integration.create(backfill_key: "bfkey", backfill_secret: "bfsek")
      bfjob = Webhookdb::Fixtures.backfill_job.for(sint).create(finished_at: Time.now)
      expect do
        @logs = capture_logs_from(Sidekiq.logger, level: :info, formatter: :json) do
          Amigo.publish("webhookdb.backfilljob.run", bfjob.id)
        end
      end.to perform_async_job(Webhookdb::Jobs::Backfill)
      expect(@logs).to include(match(/skipping_finished_backfill_job/))
    end

    it "noops if the job does not exist" do
      expect do
        @logs = capture_logs_from(Sidekiq.logger, level: :info, formatter: :json) do
          Amigo.publish("webhookdb.backfilljob.run", 0)
        end
      end.to perform_async_job(Webhookdb::Jobs::Backfill)
      expect(@logs).to include(match(/skipping_missing_backfill_job/))
    end

    it "noops if credentials are missing" do
      sint = Webhookdb::Fixtures.service_integration.create
      bfjob = Webhookdb::Fixtures.backfill_job.for(sint).create
      expect do
        @logs = capture_logs_from(Sidekiq.logger, level: :info, formatter: :json) do
          Amigo.publish("webhookdb.backfilljob.run", bfjob.id)
        end
      end.to perform_async_job(Webhookdb::Jobs::Backfill)
      expect(@logs).to include(match(/skipping_backfill_job_without_credentials/))
      expect(bfjob.refresh).to be_finished
    end

    it "noops if the row is locked", db: :no_transaction do
      sint = Webhookdb::Fixtures.service_integration.create(backfill_key: "bfkey", backfill_secret: "bfsek")
      bfjob = Webhookdb::Fixtures.backfill_job.for(sint).create
      thread_took_lock_event = Concurrent::Event.new
      thread_can_finish_event = Concurrent::Event.new
      t = Thread.new do
        Sequel.connect(Webhookdb::Postgres::Model.uri) do |conn|
          conn.transaction do
            conn << "SELECT * FROM backfill_jobs WHERE id = #{bfjob.id} FOR UPDATE"
            thread_took_lock_event.set
            thread_can_finish_event.wait
          end
        end
      end
      thread_took_lock_event.wait
      expect do
        @logs = capture_logs_from(Sidekiq.logger, level: :info, formatter: :json) do
          Amigo.publish("webhookdb.backfilljob.run", bfjob.id)
        end
      end.to perform_async_job(Webhookdb::Jobs::Backfill)
      thread_can_finish_event.set
      t.join
      expect(@logs).to include(match(/skipping_locked_backfill_job/))
    end
  end

  describe "CreateMirrorTable" do
    it "creates the table for the service integration" do
      org = Webhookdb::Fixtures.organization.create
      org.prepare_database_connections
      sint = nil
      expect do
        sint = Webhookdb::Fixtures.service_integration(organization: org).create
      end.to perform_async_job(Webhookdb::Jobs::CreateMirrorTable)

      expect(sint).to_not be_nil
      Webhookdb::Replicator.create(sint).admin_dataset do |ds|
        expect(ds.db).to be_table_exists(sint&.table_name)
      end
    ensure
      org.remove_related_database
    end
  end

  describe "CreateStripeCustomer" do
    it "registers the customer" do
      Webhookdb::Subscription.billing_enabled = true
      req = stub_request(:post, "https://api.stripe.com/v1/customers").
        to_return(body: load_fixture_data("stripe/customer_create", raw: true))
      expect do
        Webhookdb::Fixtures.organization.create(stripe_customer_id: "")
      end.to perform_async_job(Webhookdb::Jobs::CreateStripeCustomer)
      expect(req).to have_been_made
    end

    it "noops if billing is disabled" do
      Webhookdb::Subscription.billing_enabled = false
      expect do
        Webhookdb::Fixtures.organization.create(stripe_customer_id: "")
      end.to perform_async_job(Webhookdb::Jobs::CreateStripeCustomer)
    ensure
      Webhookdb::Subscription.reset_configuration
    end
  end

  describe "CustomerCreatedNotifyInternal" do
    it "publishes a developer alert" do
      expect do
        Webhookdb::Fixtures.customer.create
      end.to perform_async_job(Webhookdb::Jobs::CustomerCreatedNotifyInternal).
        and(publish("webhookdb.developeralert.emitted").with_payload(
              contain_exactly(include("subsystem" => "Customer Created")),
            ))
    end
  end

  describe "deprecated jobs" do
    it "exist as job classes" do
      expect(defined? Webhookdb::Jobs::Test::DeprecatedJob).to be_truthy
      expect(Webhookdb::Jobs::Test::DeprecatedJob).to respond_to(:perform_async)
    end
  end

  describe "DemoModeSyncData", reset_configuration: Webhookdb::DemoMode do
    let(:org) { Webhookdb::Fixtures.organization.create }

    before(:each) do
      Webhookdb::DemoMode.client_enabled = true
    end

    it "syncs demo data for the given org if enabled" do
      req = stub_request(:post, "https://api.webhookdb.com/v1/demo/data").
        to_return(json_response({data: []}))

      org.prepare_database_connections
      expect do
        org.publish_immediate("syncdemodata", org.id)
      end.to perform_async_job(Webhookdb::Jobs::DemoModeSyncData)

      expect(req).to have_been_made
    ensure
      org.remove_related_database
    end

    it "raises a retry if the org has no database yet" do
      expect do
        Webhookdb::Jobs::DemoModeSyncData.new.perform(Amigo::Event.create("", [org.id]).as_json)
      end.to raise_error(Amigo::Retry::OrDie)
    end
  end

  describe "DeveloperAlertHandle", :slack do
    it "posts to Slack" do
      alert = Webhookdb::DeveloperAlert.new(
        subsystem: "Sales",
        emoji: ":dollar:",
        fallback: "message",
        fields: [
          {title: "Greeting", value: "hello", short: false},
        ],
      )
      expect do
        alert.emit
      end.to perform_async_job(Webhookdb::Jobs::DeveloperAlertHandle)
      expect(Webhookdb::Slack.http_client.posts).to have_length(1)
    end
  end

  describe "DurableJobRecheckPoller" do
    before(:all) do
      Amigo::DurableJob.reset_configuration
    end

    it "runs DurableJob.poll_jobs" do
      Amigo::DurableJob.reset_configuration(enabled: true)
      # Ensure polling is called, but it should be early-outed.
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Sidekiq::RetrySet).to receive(:new).and_return(double(size: 1000))
      # rubocop:enable RSpec/VerifiedDoubles
      Webhookdb::Jobs::DurableJobRecheckPoller.new.perform
    end
  end

  describe "IcalendarEnqueueSyncs" do
    let(:org) { Webhookdb::Fixtures.organization.create }
    let(:sint) do
      Webhookdb::Fixtures.service_integration(organization: org).create(service_name: "icalendar_calendar_v1")
    end

    before(:each) do
      org.prepare_database_connections
      sint.replicator.create_table
    end

    after(:each) do
      org.remove_related_database
    end

    it "enqueues a splayed calendar sync for integration row needing a sync", sidekiq: :fake do
      sint.replicator.admin_dataset do |ds|
        ds.insert(
          data: "{}",
          row_created_at: Time.now,
          row_updated_at: Time.now,
          external_id: "abc",
        )
        ds.insert(
          data: "{}",
          row_created_at: Time.now,
          row_updated_at: Time.now,
          external_id: "xyz",
        )
      end
      Webhookdb::Jobs::IcalendarEnqueueSyncs.new.perform(true)
      expect(Sidekiq).to have_queue.consisting_of(
        job_hash(Webhookdb::Jobs::IcalendarSync, args: [sint.id, "abc"], at: be > Time.now.to_f),
        job_hash(Webhookdb::Jobs::IcalendarSync, args: [sint.id, "xyz"], at: be > Time.now.to_f),
      )
    end
  end

  describe "IcalendarSync" do
    let(:org) { Webhookdb::Fixtures.organization.create }
    let(:sint) do
      Webhookdb::Fixtures.service_integration(organization: org).create(service_name: "icalendar_calendar_v1")
    end

    before(:each) do
      org.prepare_database_connections
      sint.replicator.create_table
    end

    after(:each) do
      org.remove_related_database
    end

    it "syncs the row" do
      row = sint.replicator.admin_dataset do |ds|
        ds.insert(
          data: "{}",
          row_created_at: Time.now,
          row_updated_at: Time.now,
          external_id: "abc",
        )
        ds.first
      end
      expect(row).to include(last_synced_at: nil)
      Webhookdb::Jobs::IcalendarSync.new.perform(sint.id, row.fetch(:external_id))
      expect(sint.replicator.admin_dataset(&:first)).to include(last_synced_at: match_time(:now))
    end
  end

  describe "LoggedWebhookReplay" do
    it "replays the logged webhook" do
      lwh = Webhookdb::Fixtures.logged_webhook.create(request_path: "/foo")
      res = stub_request(:post, "http://localhost:18001/foo").and_return(status: 202)
      expect do
        lwh.publish_immediate("replay", lwh.id)
      end.to perform_async_job(Webhookdb::Jobs::LoggedWebhooksReplay)
      expect(res).to have_been_made
    end
  end

  describe "LoggedWebhookResilientReplay" do
    it "calls the method" do
      expect(Webhookdb::LoggedWebhook).to receive(:resilient_replay)
      # Use mocking because setting this up for real is painful
      Webhookdb::Jobs::LoggedWebhooksResilientReplay.new.perform
    end
  end

  describe "MessageDispatched", :messaging do
    it "sends the delivery on create" do
      email = "wibble@lithic.tech"

      expect do
        Webhookdb::Messages::Testers::Basic.new.dispatch(email)
      end.to perform_async_job(Webhookdb::Jobs::MessageDispatched)

      expect(Webhookdb::Message::Delivery).to have_row(to: email).
        with_attributes(transport_message_id: be_a(String))
    end
  end

  describe "PrepareDatabaseConnections" do
    let(:org) { Webhookdb::Fixtures.organization.create }

    after(:each) do
      org.remove_related_database
      Webhookdb.reset_configuration
      Webhookdb::Organization::DbBuilder.reset_configuration
    end

    it "creates the database urls for the organization" do
      expect do
        org.publish_immediate("create", org.id, org.values)
      end.to perform_async_job(Webhookdb::Jobs::PrepareDatabaseConnections)

      org.refresh
      expect(org).to have_attributes(
        admin_connection_url: start_with("postgres://"),
        readonly_connection_url: start_with("postgres://"),
        public_host: be_blank,
      )
    end

    it "sets the public host" do
      fixture = load_fixture_data("cloudflare/create_zone_dns")
      fixture["result"].merge!("type" => "CNAME", "name" => "myorg2.db.testing.dev")
      req = stub_request(:post, "https://api.cloudflare.com/client/v4/zones/testdnszoneid/dns_records").
        to_return(status: 200, body: fixture.to_json)
      Webhookdb::Organization::DbBuilder.create_cname_for_connection_urls = true

      expect do
        org.publish_immediate("create", org.id, org.values)
      end.to perform_async_job(Webhookdb::Jobs::PrepareDatabaseConnections)

      expect(req).to have_been_made

      org.refresh
      expect(org).to have_attributes(
        admin_connection_url: start_with("postgres://"),
        readonly_connection_url: start_with("postgres://"),
        public_host: eq("myorg2.db.testing.dev"),
      )
    end
  end

  describe "ProcessWebhook" do
    it "passes the payload off to the processor" do
      sint = Webhookdb::Fixtures.service_integration.create
      sint.organization.prepare_database_connections
      Webhookdb::Replicator.create(sint).create_table
      expect do
        Amigo.publish(
          "webhookdb.serviceintegration.webhook",
          sint.id,
          {
            headers: {},
            body: {"my_id" => "xyz", "at" => "Thu, 30 Jul 2015 21:12:33 +0000"},
            request_path: "/abc",
            request_method: "POST",
          },
        )
      end.to perform_async_job(Webhookdb::Jobs::ProcessWebhook)
      Webhookdb::Replicator.create(sint).readonly_dataset do |ds|
        expect(ds.all).to have_length(1)
      end
    ensure
      sint.organization.remove_related_database
    end

    it "can calculate semaphore details" do
      sint = Webhookdb::Fixtures.service_integration.create
      sint.organization.update(job_semaphore_size: 6)
      j = Webhookdb::Jobs::ProcessWebhook.new
      j.before_perform({"id" => "1", "name" => "topic", "payload" => [sint.id]})
      expect(j).to have_attributes(semaphore_key: "semaphore-procwebhook-#{sint.organization_id}", semaphore_size: 6)
    end
  end

  describe "OrganizationDatabaseMigrationRun" do
    it "starts running the migration on creation" do
      org = Webhookdb::Fixtures.organization.create
      org.prepare_database_connections
      dbinfo = Webhookdb::Organization::DbBuilder.new(org).prepare_database_connections
      expect do
        Webhookdb::Organization::DatabaseMigration.enqueue(
          admin_connection_url_raw: dbinfo.admin_url,
          readonly_connection_url_raw: dbinfo.readonly_url,
          public_host: "",
          started_by: nil,
          organization: org,
        )
      end.to perform_async_job(Webhookdb::Jobs::OrganizationDatabaseMigrationRun)
      expect(Webhookdb::Organization::DatabaseMigration.first).to have_attributes(
        started_at: match_time(Time.now).within(5),
      )
    end

    it "noops if the migration is already finished" do
      org = Webhookdb::Fixtures.organization.create
      org.prepare_database_connections
      dbinfo = Webhookdb::Organization::DbBuilder.new(org).prepare_database_connections
      dbm = Webhookdb::Organization::DatabaseMigration.enqueue(
        admin_connection_url_raw: dbinfo.admin_url,
        readonly_connection_url_raw: dbinfo.readonly_url,
        public_host: "",
        started_by: nil,
        organization: org,
      )
      dbm.update(finished_at: Time.now)
      expect do
        dbm.publish_immediate("created", dbm.id)
      end.to perform_async_job(Webhookdb::Jobs::OrganizationDatabaseMigrationRun)
    end
  end

  describe "OrganizationDatabaseMigrationNotifyStarted" do
    it "sends an email when the migration has started" do
      org = Webhookdb::Fixtures.organization.create
      admin1 = Webhookdb::Fixtures.customer.admin_in_org(org).create
      admin2 = Webhookdb::Fixtures.customer.admin_in_org(org).create
      Webhookdb::Fixtures.customer.verified_in_org(org).create
      dbm = Webhookdb::Fixtures.organization_database_migration(organization: org).with_urls.create
      expect do
        dbm.update(started_at: Time.now)
      end.to perform_async_job(Webhookdb::Jobs::OrganizationDatabaseMigrationNotifyStarted)
      expect(Webhookdb::Message::Delivery.all).to contain_exactly(
        have_attributes(
          template: "org_database_migration_started",
          to: admin1.email,
        ),
        have_attributes(
          template: "org_database_migration_started",
          to: admin2.email,
        ),
      )
    end
  end

  describe "OrganizationDatabaseMigrationFinished" do
    it "sends an email when the migration has finished" do
      org = Webhookdb::Fixtures.organization.create
      admin1 = Webhookdb::Fixtures.customer.admin_in_org(org).create
      admin2 = Webhookdb::Fixtures.customer.admin_in_org(org).create
      Webhookdb::Fixtures.customer.verified_in_org(org).create
      dbm = Webhookdb::Fixtures.organization_database_migration(organization: org).with_urls.create
      expect do
        dbm.update(finished_at: Time.now)
      end.to perform_async_job(Webhookdb::Jobs::OrganizationDatabaseMigrationNotifyFinished)
      expect(Webhookdb::Message::Delivery.all).to contain_exactly(
        have_attributes(
          template: "org_database_migration_finished",
          to: admin1.email,
        ),
        have_attributes(
          template: "org_database_migration_finished",
          to: admin2.email,
        ),
      )
    end
  end

  describe "ReplicationMigration" do
    let(:fake_sint) { Webhookdb::Fixtures.service_integration.create }
    let(:o) { fake_sint.organization }
    let(:fake) { fake_sint.replicator }

    before(:each) do
      o.prepare_database_connections
      fake.create_table
    end

    after(:each) do
      o.remove_related_database
    end

    it "migrates the org replication tables if the target release_created_at (RCA) matches the current RCA",
       sidekiq: :fake do
      fake.admin_dataset do |ds|
        expect(ds.columns).to contain_exactly(:pk, :my_id, :at, :data)
        # Drop a column to make sure it gets migrated back in
        ds.db << "ALTER TABLE #{fake_sint.table_name} DROP COLUMN at"
      end
      expect(Webhookdb::Jobs::ReplicationMigration).to receive(:migrate_org).and_call_original

      Webhookdb::Jobs::ReplicationMigration.new.perform(o.id, Webhookdb::RELEASE_CREATED_AT)

      fake.admin_dataset do |ds|
        # Assert the dropped column is restored
        expect(ds.columns).to contain_exactly(:pk, :my_id, :at, :data)
      end
      expect(Sidekiq).to have_empty_queues
    end

    it "re-enqueues the job to the future if the target RCA is after the current RCA", sidekiq: :fake do
      stub_const("Webhookdb::RELEASE_CREATED_AT", "2000-01-01T00:00:00Z")
      target_rca = "2001-01-01T00:00:00Z"

      expect(Webhookdb::Jobs::ReplicationMigration).to_not receive(:migrate_org)

      t = Time.now
      Timecop.freeze(t) do
        Webhookdb::Jobs::ReplicationMigration.new.perform(o.id, target_rca)
      end

      expect(Sidekiq).to have_queue.consisting_of(
        job_hash(
          Webhookdb::Jobs::ReplicationMigration,
          at: match_time(t + 1.second),
          args: [o.id, target_rca],
        ),
      )
    end

    it "drops the job if the target RCA is before the current RCA", sidekiq: :fake do
      stub_const("Webhookdb::RELEASE_CREATED_AT", "2000-01-01T00:00:00Z")
      target_rca = "1999-01-01T00:00:00Z"

      expect(Webhookdb::Jobs::ReplicationMigration).to_not receive(:migrate_org)

      Webhookdb::Jobs::ReplicationMigration.new.perform(o.id, target_rca)
      expect(Sidekiq).to have_empty_queues
    end
  end

  describe "ResetCodeCreateDispatch" do
    it "sends an email for an email reset code" do
      customer = Webhookdb::Fixtures.customer(email: "maryjane@lithic.tech").create
      expect do
        customer.add_reset_code(token: "12345", transport: "email")
      end.to perform_async_job(Webhookdb::Jobs::ResetCodeCreateDispatch)
      expect(Webhookdb::Message::Delivery.all).to contain_exactly(
        have_attributes(
          template: "verification",
          transport_type: "email",
          to: "maryjane@lithic.tech",
          bodies: include(
            have_attributes(content: match(/12345/)),
          ),
        ),
      )
    end
  end

  describe "AtomSingleFeedPoller" do
    it "backfills atom feed integrations" do
      sint = Webhookdb::Fixtures.service_integration.create(service_name: "atom_single_feed_v1")

      expect do
        Webhookdb::Jobs::AtomSingleFeedPoller.new.perform(true)
      end.to publish("webhookdb.backfilljob.run").with_payload(contain_exactly(be_positive))
      expect(Webhookdb::BackfillJob.first).to have_attributes(
        service_integration: be === sint,
        incremental: true,
      )
    end
  end

  describe "SendInvite" do
    it "sends an email with an invitation code" do
      membership = Webhookdb::Fixtures.organization_membership.
        customer(email: "lucy@lithic.tech").
        invite.
        code("join-abcxyz").
        create
      expect do
        Amigo.publish(
          "webhookdb.organizationmembership.invite", membership.id,
        )
      end.to perform_async_job(Webhookdb::Jobs::SendInvite)
      expect(Webhookdb::Message::Delivery.first).to have_attributes(
        template: "invite",
        transport_type: "email",
        to: "lucy@lithic.tech",
        bodies: include(
          have_attributes(content: match(/join-abcxyz/)),
        ),
      )
    end
  end

  describe "SyncTargetEnqueueScheduled" do
    it "runs sync targets that are due", sidekiq: :fake do
      never_run = Webhookdb::Fixtures.sync_target.create
      run_recently = Webhookdb::Fixtures.sync_target.create(last_synced_at: Time.now)
      Webhookdb::Jobs::SyncTargetEnqueueScheduled.new.perform(true)
      expect(Sidekiq).to have_queue("netout").consisting_of(
        # jitter is random, so must use be_positive
        job_hash(Webhookdb::Jobs::SyncTargetRunSync, at: be_positive, args: [never_run.id]),
      )
    end
  end

  describe "SyncTargetRunSync" do
    let(:sint) { Webhookdb::Fixtures.service_integration.create }

    before(:each) do
      sint.organization.prepare_database_connections
      sint.replicator.create_table
    end

    after(:each) do
      sint.organization.remove_related_database
    end

    it "runs the sync" do
      stgt = Webhookdb::Fixtures.sync_target(service_integration: sint).postgres.create
      Webhookdb::Jobs::SyncTargetRunSync.new.perform(stgt.id)
      expect(stgt.refresh).to have_attributes(last_synced_at: be_within(5).of(Time.now))
    end

    it "noops if a sync is in progress" do
      orig_sync = 3.hours.ago
      stgt = Webhookdb::Fixtures.sync_target(service_integration: sint).postgres.create(last_synced_at: orig_sync)
      Sequel.connect(Webhookdb::Postgres::Model.uri) do |otherconn|
        Sequel::AdvisoryLock.new(otherconn, Webhookdb::SyncTarget::ADVISORY_LOCK_KEYSPACE, stgt.id).with_lock do
          Webhookdb::Jobs::SyncTargetRunSync.new.perform(stgt.id)
        end
      end
      expect(stgt.refresh).to have_attributes(last_synced_at: match_time(orig_sync))
    end

    it "noops if the sync target does not exist" do
      expect do
        Webhookdb::Jobs::SyncTargetRunSync.new.perform(0)
      end.to_not raise_error
    end
  end

  describe "Webhook Subscription jobs" do
    let!(:sint) { Webhookdb::Fixtures.service_integration.create }
    let!(:webhook_sub) do
      Webhookdb::Fixtures.webhook_subscription.create(service_integration: sint)
    end

    describe "SendWebhook" do
      it "sends request to correct endpoint" do
        req = stub_request(:post, webhook_sub.deliver_to_url).to_return(status: 200, body: "", headers: {})
        Webhookdb::Jobs::SendWebhook.new.perform(Amigo::Event.create(
          "",
          [
            sint.id,
            {
              row: {},
              external_id_column: "external id column",
              external_id: "external id",
            },
          ],
        ).as_json)
        expect(req).to have_been_made
      end

      it "does not query for deactivated subscriptions" do
        webhook_sub.deactivate.save_changes
        expect do
          Amigo.publish(
            "webhookdb.serviceintegration.rowupsert",
            sint.id,
            {
              row: {},
              external_id_column: "external id column",
              external_id: "external id",
            },
          )
        end.to perform_async_job(Webhookdb::Jobs::SendWebhook)
        expect(Webhookdb::WebhookSubscription::Delivery.all).to be_empty
      end
    end

    describe "SendTestWebhook" do
      it "sends request to correct endpoint" do
        req = stub_request(:post, webhook_sub.deliver_to_url).to_return(status: 200, body: "", headers: {})
        expect do
          Amigo.publish(
            "webhookdb.webhooksubscription.test", webhook_sub.id,
          )
        end.to perform_async_job(Webhookdb::Jobs::SendTestWebhook)
        expect(req).to have_been_made
      end
    end
  end

  describe "SignalwireMessageBackfill" do
    it "enqueues backfill job for signalwire message integrations" do
      sint = Webhookdb::Fixtures.service_integration.create(
        service_name: "signalwire_message_v1",
      )
      expect do
        Webhookdb::Jobs::SignalwireMessageBackfill.new.perform
      end.to publish("webhookdb.backfilljob.run", contain_exactly(be_positive))
      expect(Webhookdb::BackfillJob.first).to have_attributes(
        service_integration: be === sint,
        incremental: true,
      )
    end
  end

  describe "SponsyScheduledBackfill" do
    it "enqueues cascading backfill job for all sponsy auth integrations" do
      auth_sint = Webhookdb::Fixtures.service_integration.create(service_name: "sponsy_publication_v1")
      expect do
        Webhookdb::Jobs::SponsyScheduledBackfill.new.perform
      end.to publish("webhookdb.backfilljob.run", contain_exactly(be_positive))
      expect(Webhookdb::BackfillJob.first).to have_attributes(
        service_integration: be === auth_sint,
        incremental: true,
      )
    end
  end

  describe "TrimLoggedWebhooks" do
    it "runs LoggedWebhooks.trim_table" do
      old = Webhookdb::Fixtures.logged_webhook.ancient.create
      newer = Webhookdb::Fixtures.logged_webhook.create
      Webhookdb::Jobs::TrimLoggedWebhooks.new.perform
      expect(Webhookdb::LoggedWebhook.all).to have_same_ids_as(newer)
    end
  end

  describe "TwilioSmsBackfill" do
    it "enqueues backfill job for all twilio service integrations" do
      sint = Webhookdb::Fixtures.service_integration.create(
        service_name: "twilio_sms_v1",
      )
      expect do
        Webhookdb::Jobs::TwilioSmsBackfill.new.perform
      end.to publish("webhookdb.backfilljob.run", contain_exactly(be_positive))
      expect(Webhookdb::BackfillJob.first).to have_attributes(
        service_integration: be === sint,
        incremental: true,
      )
    end
  end

  describe "WebhookdbResourceNotifyIntegrations" do
    it "POSTs to webhookdb service integrations on change" do
      sint = Webhookdb::Fixtures.service_integration.create(service_name: "webhookdb_customer_v1")

      req = stub_request(:post, "http://localhost:18001/v1/service_integrations/#{sint.opaque_id}").
        with(body: hash_including("id", "created_at")).
        to_return(status: 202, body: "ok")

      expect do
        Webhookdb::Fixtures.customer.create
      end.to perform_async_job(Webhookdb::Jobs::WebhookdbResourceNotifyIntegrations)

      expect(req).to have_been_made
    end
  end
end
