# frozen_string_literal: true

require "support/shared_examples_for_replicators"

# rubocop:disable Layout/LineLength
RSpec.describe Webhookdb::Replicator::IcalendarCalendarV1, :db do
  let(:org) { Webhookdb::Fixtures.organization.create }
  let(:fac) { Webhookdb::Fixtures.service_integration(organization: org) }
  let(:sint) { fac.stable_encryption_secret.create(service_name: "icalendar_calendar_v1") }
  let(:svc) { sint.replicator }
  let(:event_sint) { fac.depending_on(sint).create(service_name: "icalendar_event_v1") }
  let(:event_svc) { event_sint.replicator }

  def insert_calendar_row(**more)
    svc.admin_dataset do |ds|
      inserted = ds.returning(Sequel.lit("*")).
        insert(
          data: "{}",
          row_created_at: Time.now,
          row_updated_at: Time.now,
          **more,
        )
      return inserted.first
    end
  end

  it_behaves_like "a replicator", "icalendar_calendar_v1" do
    let(:sint) { super() }
    let(:body) do
      JSON.parse(<<~J)
        {
          "type": "__WHDB_UNIT_TEST",
          "external_id": "123",
          "ics_url": "https://foo.bar/basic.ics"
        }
      J
    end
    let(:expected_row) do
      include(
        :pk,
        data: {},
        ics_url: "https://foo.bar/basic.ics",
        external_id: "123",
        row_created_at: match_time(:now),
        row_updated_at: match_time(:now),
        last_synced_at: nil,
      )
    end
    let(:supports_row_diff) { false }
  end

  it_behaves_like "a replicator with dependents", "icalendar_calendar_v1", "icalendar_event_v1" do
    let(:sint) { super() }
    let(:body) do
      JSON.parse(<<~J)
        {
          "type": "__WHDB_UNIT_TEST",
          "external_id": "123",
          "ics_url": "https://foo"
        }
      J
    end
    let(:can_track_row_changes) { false }
    let(:expected_insert) do
      {
        data: "{}",
        external_id: "123",
        ics_url: "https://foo",
        last_synced_at: nil,
        row_created_at: match_time(:now),
        row_updated_at: match_time(:now),
      }
    end
  end

  describe "upsert behavior" do
    describe "upsert_webhook" do
      let(:base_request) do
        {
          "external_id" => "456",
          "ics_url" => "https://foo.bar/basic.ics",
        }
      end

      before(:each) do
        org.prepare_database_connections
        svc.create_table
      end

      after(:each) do
        org.remove_related_database
      end

      it "responds to `SYNC` requests by upserting and enqueing a sync", sidekiq: :fake do
        body = {"ics_url" => "https://abc.url", "external_id" => "456", "type" => "SYNC"}
        svc.upsert_webhook_body(body)

        svc.readonly_dataset do |ds|
          expect(ds.all).to contain_exactly(
            include(
              ics_url: "https://abc.url",
              external_id: "456",
            ),
          )
        end
        expect(Sidekiq).to have_queue.consisting_of(
          job_hash(Webhookdb::Jobs::IcalendarSync, args: [sint.id, "456"]),
        )
      end

      it "selectively stomps fields" do
        body = {"type" => "__WHDB_UNIT_TEST", "external_id" => "123", "ics_url" => "https://a.b"}
        svc.upsert_webhook_body(body)

        row1 = svc.readonly_dataset(&:first)
        expect(row1[:row_updated_at]).to match_time(:now)
        updated = 1.hour.from_now
        Timecop.travel(updated) do
          svc.upsert_webhook_body(body.merge("ics_url" => "https://y.z"))
        end
        expect(svc.readonly_dataset(&:all)).to contain_exactly(
          include(
            external_id: "123",
            row_created_at: match_time(row1[:row_created_at]),
            row_updated_at: match_time(updated).within(1.second),
            ics_url: "https://y.z",
          ),
        )
      end

      it "replaces webcal protocol with https", sidekiq: :fake do
        body = {"ics_url" => "webcal://abc.url", "external_id" => "456", "type" => "SYNC"}
        svc.upsert_webhook_body(body)

        svc.readonly_dataset do |ds|
          expect(ds.all).to contain_exactly(
            include(
              ics_url: "https://abc.url",
              external_id: "456",
            ),
          )
        end
        expect(Sidekiq).to have_queue.consisting_of(
          job_hash(Webhookdb::Jobs::IcalendarSync, args: [sint.id, "456"]),
        )
      end

      it "responds to `DELETE` request by deleting all relevant calendar data" do
        event_svc.create_table

        insert_calendar_row(ics_url: "https://x.y", external_id: "456")
        insert_calendar_row(ics_url: "https://x.y", external_id: "567")
        event_svc.admin_dataset do |event_ds|
          event_ds.multi_insert(
            [
              {data: "{}", uid: "c", calendar_external_id: "456", compound_identity: "456-c"},
              {data: "{}", uid: "d", calendar_external_id: "567", compound_identity: "567-d"},
            ],
          )
        end

        body = {"external_id" => "456", "type" => "DELETE"}
        svc.upsert_webhook_body(body)

        expect(svc.readonly_dataset(&:all)).to contain_exactly(include(external_id: "567"))
        expect(event_svc.readonly_dataset(&:all)).to contain_exactly(include(uid: "d"))
      end

      it "raises error for unknown request type" do
        body = {"refresh_token" => "refrok", "external_id" => "456", "type" => "REMIX"}
        expect do
          svc.upsert_webhook_body(body)
        end.to raise_error(ArgumentError, "Unknown request type: REMIX")
      end
    end
  end

  describe "state machine calculation" do
    describe "calculate_webhook_state_machine" do
      it "prompts for the secret" do
        sm = sint.replicator.calculate_webhook_state_machine
        expect(sm).to have_attributes(
          needs_input: true,
          complete: false,
          output: include("about to add support for replicating iCalendar"),
          prompt: include("secret"),
        )
      end

      it "completes if secret is set" do
        sint.webhook_secret = "abc"
        sm = sint.replicator.calculate_webhook_state_machine
        expect(sm).to have_attributes(
          needs_input: false,
          complete: true,
          output: include("All set! Here is the endpoint"),
        )
      end
    end
  end

  it_behaves_like "a replicator with a custom backfill not supported message", "icalendar_calendar_v1"

  describe "webhook_response" do
    it "validates using Whdb-Webhook-Secret" do
      sint.webhook_secret = "goodsecret"
      badreq = fake_request
      badreq.add_header("HTTP_WHDB_WEBHOOK_SECRET", "badsecret")
      expect(svc.webhook_response(badreq)).to have_attributes(status: 401)

      goodreq = fake_request
      goodreq.add_header("HTTP_WHDB_WEBHOOK_SECRET", "goodsecret")
      expect(svc.webhook_response(goodreq)).to have_attributes(status: 202)
    end
  end

  describe "rows_needing_sync" do
    before(:each) do
      org.prepare_database_connections
      svc.create_table
    end

    after(:each) do
      org.remove_related_database
    end

    it "selects rows that have not been synced in 4 hours" do
      sync1 = insert_calendar_row(ics_url: "https://x.y", external_id: "abc")
      sync2 = insert_calendar_row(ics_url: "https://x.y", external_id: "def", last_synced_at: 12.hours.ago)
      nosync = insert_calendar_row(ics_url: "https://x.y", external_id: "xyz", last_synced_at: 1.hour.ago)

      rows = svc.admin_dataset { |ds| svc.rows_needing_sync(ds).all }
      expect(rows).to contain_exactly(include(pk: sync1[:pk]), include(pk: sync2[:pk]))
    end
  end

  describe "sync_row" do
    before(:each) do
      org.prepare_database_connections
      svc.create_table
      event_svc.create_table
    end

    after(:each) do
      org.remove_related_database
    end

    it "upserts each vevent in the url" do
      literal = '\n\r\n\t\n'
      body = <<~ICAL
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//ZContent.net//Zap Calendar 1.0//EN
        CALSCALE:GREGORIAN
        METHOD:PUBLISH
        BEGIN:VEVENT
        SUMMARY:Abraham Lincoln
        UID:c7614cff-3549-4a00-9152-d25cc1fe077d
        SEQUENCE:0
        STATUS:CONFIRMED
        TRANSP:TRANSPARENT
        DTSTART:20080212
        DTEND:20080213
        DTSTAMP:20150421T141403
        CATEGORIES:U.S. Presidents,Civil War People
        LOCATION:Hodgenville, Kentucky
        GEO:37.5739497;-85.7399606
        DESCRIPTION:Born February 12, 1809\\nSixteenth President (1861-1865)#{literal}
         \\nhttp://AmericanHistoryCalendar.com
        URL:http://americanhistorycalendar.com/peoplecalendar/1,328-abraham-lincol
         n
        END:VEVENT
        END:VCALENDAR
      ICAL
      req = stub_request(:get, "https://feed.me").
        and_return(status: 200, headers: {"Content-Type" => "text/calendar"}, body:)
      row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
      svc.sync_row(row)
      expect(svc.admin_dataset(&:first)).to include(last_synced_at: match_time(:now))
      expect(req).to have_been_made
      expect(event_svc.admin_dataset(&:all)).to contain_exactly(
        include(
          calendar_external_id: "abc",
          categories: ["U.S. Presidents", "Civil War People"],
          classification: nil,
          compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d",
          created_at: nil,
          data: hash_including(
            "DTEND" => {"v" => "20080213"},
            "DESCRIPTION" => {"v" => "Born February 12, 1809\nSixteenth President (1861-1865)\n\r\n\t\n\nhttp://AmericanHistoryCalendar.com"},
            "URL" => {"v" => "http://americanhistorycalendar.com/peoplecalendar/1,328-abraham-lincoln"},
          ),
          end_at: nil,
          end_date: Date.parse("Wed, 13 Feb 2008"),
          geo_lat: 37.5739497,
          geo_lng: -85.7399606,
          last_modified_at: match_time(:now),
          priority: nil,
          row_updated_at: match_time(:now),
          start_at: nil,
          start_date: Date.parse("Tue, 12 Feb 2008"),
          status: "CONFIRMED",
          uid: "c7614cff-3549-4a00-9152-d25cc1fe077d",
        ),
      )
    end

    it "noops if there's no event integration" do
      event_sint.destroy
      row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
      svc.sync_row(row)
      expect(svc.admin_dataset(&:first)).to include(last_synced_at: match_time(:now))
    end

    it "skips rows that have not been modified" do
      v1 = <<~ICAL
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//ZContent.net//Zap Calendar 1.0//EN
        CALSCALE:GREGORIAN
        BEGIN:VEVENT
        SUMMARY:Version1
        UID:c7614cff-3549-4a00-9152-d25cc1fe077d
        DTSTART:20080212
        DTEND:20080213
        LAST-MODIFIED:20150421T141403Z
        END:VEVENT
        END:VCALENDAR
      ICAL
      updated1 = v1.gsub("Version1", "Version2")
      updated2 = v1.gsub("Version1", "Version3").gsub("20150421T141403Z", "20160421T141403Z")
      updated3 = v1.gsub("Version1", "Version4").gsub("\nLAST-MODIFIED:20150421T141403Z", "")
      req = stub_request(:get, "https://feed.me").
        and_return(
          {status: 200, headers: {"Content-Type" => "text/calendar"}, body: v1},
          {status: 200, headers: {"Content-Type" => "text/calendar"}, body: updated1},
          {status: 200, headers: {"Content-Type" => "text/calendar"}, body: updated2},
          {status: 200, headers: {"Content-Type" => "text/calendar"}, body: updated3},
        )
      row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
      svc.sync_row(row)
      expect(event_svc.admin_dataset(&:all)).to contain_exactly(
        include(data: hash_including("SUMMARY" => {"v" => "Version1"})),
      )
      svc.sync_row(row)
      expect(event_svc.admin_dataset(&:all)).to contain_exactly(
        include(data: hash_including("SUMMARY" => {"v" => "Version1"})),
      )
      svc.sync_row(row)
      expect(event_svc.admin_dataset(&:all)).to contain_exactly(
        include(data: hash_including("SUMMARY" => {"v" => "Version3"})),
      )
      svc.sync_row(row)
      expect(event_svc.admin_dataset(&:all)).to contain_exactly(
        include(data: hash_including("SUMMARY" => {"v" => "Version4"})),
      )
      expect(req).to have_been_made.times(4)
    end

    it "uses UTC for unregonized timezones" do
      body = <<~ICAL
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Abraham Lincoln
        UID:c7614cff-3549-4a00-9152-d25cc1fe077d
        SEQUENCE:0
        STATUS:CONFIRMED
        TRANSP:TRANSPARENT
        DTSTART;TZID=Unknown:19700101T000000
        DTEND;TZID=Unknown:19710101T000000
        END:VEVENT
        END:VCALENDAR
      ICAL
      req = stub_request(:get, "https://feed.me").
        and_return(status: 200, headers: {"Content-Type" => "text/calendar"}, body:)
      row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
      svc.sync_row(row)
      expect(req).to have_been_made
      expect(event_svc.admin_dataset(&:all)).to contain_exactly(
        include(
          calendar_external_id: "abc",
          start_at: Time.parse("1970-01-01T00:00:00Z"),
          end_at: Time.parse("1971-01-01T00:00:00Z"),
          uid: "c7614cff-3549-4a00-9152-d25cc1fe077d",
        ),
      )
    end

    it "cancels events added previously no longer present in the calendar" do
      body1 = <<~ICAL
        BEGIN:VEVENT
        UID:keep_existing
        DTSTART:20080212
        DTEND:20080213
        LAST-MODIFIED:20150421T141403Z
        END:VEVENT
        BEGIN:VEVENT
        UID:go_away
        DTSTART:20080212
        DTEND:20080213
        LAST-MODIFIED:20150421T141403Z
        END:VEVENT
        BEGIN:VEVENT
        UID:recurring1
        DTSTART:20080212
        DTEND:20080213
        LAST-MODIFIED:20150421T141403Z
        RRULE:FREQ=YEARLY;UNTIL=20110101T000000Z
        END:VEVENT
      ICAL
      body2 = <<~ICAL
        BEGIN:VEVENT
        UID:keep_existing
        DTSTART:20080212
        DTEND:20080213
        LAST-MODIFIED:20150421T141403Z
        END:VEVENT
        BEGIN:VEVENT
        UID:recurring2
        DTSTART:20080212
        DTEND:20080213
        LAST-MODIFIED:20150421T141403Z
        RRULE:FREQ=YEARLY;UNTIL=20110101T000000Z
        END:VEVENT
      ICAL
      req = stub_request(:get, "https://feed.me").
        and_return(
          {status: 200, headers: {"Content-Type" => "text/calendar"}, body: body1},
          {status: 200, headers: {"Content-Type" => "text/calendar"}, body: body1},
          {status: 200, headers: {"Content-Type" => "text/calendar"}, body: body2},
        )
      abc_cal_row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
      # Make sure these events are not canceled while we cancel abc's (ensure we limit the dataset)
      xyz_cal_row = insert_calendar_row(ics_url: "https://feed.me", external_id: "xyz")
      svc.sync_row(abc_cal_row)
      svc.sync_row(xyz_cal_row)
      expect(event_svc.admin_dataset(&:all)).to contain_exactly(
        hash_including(compound_identity: "abc-keep_existing"),
        hash_including(compound_identity: "abc-go_away"),
        hash_including(compound_identity: "abc-recurring1-0"),
        hash_including(compound_identity: "abc-recurring1-1"),
        hash_including(compound_identity: "abc-recurring1-2"),
        hash_including(compound_identity: "xyz-keep_existing"),
        hash_including(compound_identity: "xyz-go_away"),
        hash_including(compound_identity: "xyz-recurring1-0"),
        hash_including(compound_identity: "xyz-recurring1-1"),
        hash_including(compound_identity: "xyz-recurring1-2"),
      )
      svc.sync_row(abc_cal_row)
      expect(req).to have_been_made.times(3)
      expect(event_svc.admin_dataset(&:all)).to contain_exactly(
        hash_including(compound_identity: "abc-keep_existing", status: nil),
        hash_including(compound_identity: "abc-go_away", status: "CANCELLED", data: hash_including("UID", "STATUS" => {"v" => "CANCELLED"})),
        hash_including(compound_identity: "abc-recurring1-0", status: "CANCELLED", data: hash_including("UID", "STATUS" => {"v" => "CANCELLED"})),
        hash_including(compound_identity: "abc-recurring1-1", status: "CANCELLED", data: hash_including("UID", "STATUS" => {"v" => "CANCELLED"})),
        hash_including(compound_identity: "abc-recurring1-2", status: "CANCELLED", data: hash_including("UID", "STATUS" => {"v" => "CANCELLED"})),
        hash_including(compound_identity: "abc-recurring2-0", status: nil),
        hash_including(compound_identity: "abc-recurring2-1", status: nil),
        hash_including(compound_identity: "abc-recurring2-2", status: nil),
        hash_including(compound_identity: "xyz-keep_existing", status: nil),
        hash_including(compound_identity: "xyz-go_away", status: nil),
        hash_including(compound_identity: "xyz-recurring1-0", status: nil),
        hash_including(compound_identity: "xyz-recurring1-1", status: nil),
        hash_including(compound_identity: "xyz-recurring1-2", status: nil),
      )
    end

    describe "alerting", :no_transaction_check do
      it "raises on unexpected errors" do
        err = RuntimeError.new("hi")
        req = stub_request(:get, "https://feed.me").to_raise(err)
        row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
        expect do
          svc.sync_row(row)
        end.to raise_error(err)
        expect(req).to have_been_made
      end

      it "alerts on too many redirects" do
        Webhookdb::Fixtures.organization_membership.org(org).verified.admin.create
        req = stub_request(:get, "https://feed.me").and_return(
          {status: 301, headers: {"Location" => "https://feed.me"}},
          {status: 301, headers: {"Location" => "https://feed.me"}},
          {status: 301, headers: {"Location" => "https://feed.me"}},
        )
        row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
        svc.sync_row(row)
        expect(req).to have_been_made.times(3)
        expect(Webhookdb::Message::Delivery.all).to contain_exactly(
          have_attributes(template: "errors/icalendar_fetch"),
        )
      end

      [400, 404, 417, 500, 503].each do |httpstatus|
        it "alerts on Down HTTP #{httpstatus} errors" do
          Webhookdb::Fixtures.organization_membership.org(org).verified.admin.create
          req = stub_request(:get, "https://feed.me").
            and_return(status: httpstatus, headers: {"Content-Type" => "text/plain"}, body: "whoops")
          row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
          svc.sync_row(row)
          expect(req).to have_been_made
          expect(Webhookdb::Message::Delivery.all).to contain_exactly(
            have_attributes(template: "errors/icalendar_fetch"),
          )
        end
      end

      it "raises on unhandled Down http errors" do
        Webhookdb::Fixtures.organization_membership.org(org).verified.admin.create
        req = stub_request(:get, "https://feed.me").
          and_return(status: 456, headers: {"Content-Type" => "text/plain"}, body: "whoops")
        row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
        expect { svc.sync_row(row) }.to raise_error(Down::ClientError, /456/)
        expect(req).to have_been_made
      end

      it "alerts on invalid url errors" do
        Webhookdb::Fixtures.organization_membership.org(org).verified.admin.create
        row = insert_calendar_row(ics_url: "webca://feed.me", external_id: "abc")
        svc.sync_row(row)
        expect(Webhookdb::Message::Delivery.all).to contain_exactly(
          have_attributes(template: "errors/icalendar_fetch"),
        )
      end

      it "alerts on Down timeout" do
        Webhookdb::Fixtures.organization_membership.org(org).verified.admin.create
        req = stub_request(:get, "https://feed.me").to_raise(Down::TimeoutError)
        row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
        svc.sync_row(row)
        expect(req).to have_been_made
        expect(Webhookdb::Message::Delivery.all).to contain_exactly(
          have_attributes(template: "errors/icalendar_fetch"),
        )
      end

      it "alerts on Down ssl errors" do
        Webhookdb::Fixtures.organization_membership.org(org).verified.admin.create
        req = stub_request(:get, "https://feed.me").to_raise(Down::SSLError)
        row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
        svc.sync_row(row)
        expect(req).to have_been_made
        expect(Webhookdb::Message::Delivery.all).to contain_exactly(
          have_attributes(template: "errors/icalendar_fetch"),
        )
      end

      it "alerts on Down connection errors" do
        Webhookdb::Fixtures.organization_membership.org(org).verified.admin.create
        req = stub_request(:get, "https://feed.me").to_raise(Down::ConnectionError)
        row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
        svc.sync_row(row)
        expect(req).to have_been_made
        expect(Webhookdb::Message::Delivery.all).to contain_exactly(
          have_attributes(template: "errors/icalendar_fetch"),
        )
      end
    end

    describe "recurrence" do
      def sync(body)
        req = stub_request(:get, "https://feed.me").
          and_return(status: 200, headers: {"Content-Type" => "text/calendar"}, body:)
        row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
        Timecop.freeze("2022-06-06") do
          svc.sync_row(row)
        end
        expect(req).to have_been_made
        events = event_svc.admin_dataset(&:all)
        return events
      end

      it "projects all past events, and recurring events up to RECURRENCE_PROJECTION forward" do
        stub_const("Webhookdb::Replicator::IcalendarCalendarV1::RECURRENCE_PROJECTION", 2.years)
        body = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART:20180101T000000Z
          DTEND:20180101T010000Z
          RRULE:FREQ=YEARLY;UNTIL=30700101T000000Z
          END:VEVENT
        ICAL
        expect(sync(body)).to contain_exactly(
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-0", calendar_external_id: "abc", uid: "c7614cff-3549-4a00-9152-d25cc1fe077d-0", start_at: Time.parse("2018-01-01 00:00:00Z"), end_at: Time.parse("2018-01-01 01:00:00Z"), recurring_event_id: "c7614cff-3549-4a00-9152-d25cc1fe077d", recurring_event_sequence: 0),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-1", calendar_external_id: "abc", uid: "c7614cff-3549-4a00-9152-d25cc1fe077d-1", start_at: Time.parse("2019-01-01 00:00:00Z"), end_at: Time.parse("2019-01-01 01:00:00Z"), recurring_event_id: "c7614cff-3549-4a00-9152-d25cc1fe077d", recurring_event_sequence: 1),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-2", calendar_external_id: "abc", uid: "c7614cff-3549-4a00-9152-d25cc1fe077d-2", start_at: Time.parse("2020-01-01 00:00:00Z"), end_at: Time.parse("2020-01-01 01:00:00Z"), recurring_event_id: "c7614cff-3549-4a00-9152-d25cc1fe077d", recurring_event_sequence: 2),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-3", calendar_external_id: "abc", uid: "c7614cff-3549-4a00-9152-d25cc1fe077d-3", start_at: Time.parse("2021-01-01 00:00:00Z"), end_at: Time.parse("2021-01-01 01:00:00Z"), recurring_event_id: "c7614cff-3549-4a00-9152-d25cc1fe077d", recurring_event_sequence: 3),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-4", calendar_external_id: "abc", uid: "c7614cff-3549-4a00-9152-d25cc1fe077d-4", start_at: Time.parse("2022-01-01 00:00:00Z"), end_at: Time.parse("2022-01-01 01:00:00Z"), recurring_event_id: "c7614cff-3549-4a00-9152-d25cc1fe077d", recurring_event_sequence: 4),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-5", calendar_external_id: "abc", uid: "c7614cff-3549-4a00-9152-d25cc1fe077d-5", start_at: Time.parse("2023-01-01 00:00:00Z"), end_at: Time.parse("2023-01-01 01:00:00Z"), recurring_event_id: "c7614cff-3549-4a00-9152-d25cc1fe077d", recurring_event_sequence: 5),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-6", calendar_external_id: "abc", uid: "c7614cff-3549-4a00-9152-d25cc1fe077d-6", start_at: Time.parse("2024-01-01 00:00:00Z"), end_at: Time.parse("2024-01-01 01:00:00Z"), recurring_event_id: "c7614cff-3549-4a00-9152-d25cc1fe077d", recurring_event_sequence: 6),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-7", calendar_external_id: "abc", uid: "c7614cff-3549-4a00-9152-d25cc1fe077d-7", start_at: Time.parse("2025-01-01 00:00:00Z"), end_at: Time.parse("2025-01-01 01:00:00Z"), recurring_event_id: "c7614cff-3549-4a00-9152-d25cc1fe077d", recurring_event_sequence: 7),
        )
      end

      it "stops projecting at the UNTIL" do
        body = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART:20180101T000000Z
          DTEND:20180101T010000Z
          RRULE:FREQ=YEARLY;UNTIL=20200101T000000Z
          END:VEVENT
        ICAL
        expect(sync(body)).to contain_exactly(
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-0", start_at: Time.parse("2018-01-01 00:00:00Z"), end_at: Time.parse("2018-01-01 01:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-1", start_at: Time.parse("2019-01-01 00:00:00Z"), end_at: Time.parse("2019-01-01 01:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-2", start_at: Time.parse("2020-01-01 00:00:00Z"), end_at: Time.parse("2020-01-01 01:00:00Z")),
        )
      end

      it "can project dates" do
        body = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART;VALUE=DATE:20180101
          DTEND;VALUE=DATE:20180102
          RRULE:FREQ=YEARLY;UNTIL=20191201T000000Z
          END:VEVENT
        ICAL
        expect(sync(body)).to contain_exactly(
          hash_including(start_date: Date.new(2018, 1, 1), end_date: Date.new(2018, 1, 2)),
          hash_including(start_date: Date.new(2019, 1, 1), end_date: Date.new(2019, 1, 2)),
        )
      end

      it "handles EXDATE (exclusion dates)" do
        body = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART:20180101T000000Z
          DTEND:20180101T010000Z
          RRULE:FREQ=YEARLY;UNTIL=20210101T000000Z
          EXDATE:20180101T000000Z
          EXDATE;TZID=Africa/Algiers:20200101T010000
          END:VEVENT
        ICAL
        rows = sync(body)
        expect(rows).to contain_exactly(
          hash_including(start_at: match_time("2019-01-01T00:00:00Z")),
          hash_including(start_at: match_time("2021-01-01T00:00:00Z")),
        )
      end

      it "handles RDATE (inclusion dates)" do
        body = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART:20180101T000000Z
          DTEND:20180101T010000Z
          RRULE:FREQ=YEARLY;UNTIL=20190101T000000Z
          RDATE;TZID=Africa/Algiers:20180301T010000
          RDATE:20200401T000000Z
          END:VEVENT
        ICAL
        rows = sync(body)
        expect(rows).to contain_exactly(
          hash_including(start_at: match_time("2018-01-01T00:00:00Z")),
          hash_including(start_at: match_time("2018-03-01T00:00:00Z")),
          hash_including(start_at: match_time("2019-01-01T00:00:00Z")),
          hash_including(start_at: match_time("2020-04-01T00:00:00Z")),
        )
      end

      it "handles RDATE and EXDATE date values" do
        body = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART;VALUE=DATE:20180101
          DTEND;VALUE=DATE:20180101
          RRULE:FREQ=YEARLY;UNTIL=20190101
          RDATE;VALUE=DATE:20180301
          EXDATE;VALUE=DATE:20180101
          END:VEVENT
        ICAL
        rows = sync(body)
        expect(rows).to contain_exactly(
          hash_including(start_date: Date.new(2018, 3, 1)),
          hash_including(start_date: Date.new(2019, 1, 1)),
        )
      end

      it "handles events with no end time" do
        body = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART:20180101T000000Z
          RRULE:FREQ=YEARLY;UNTIL=20200101T000000Z
          END:VEVENT
        ICAL
        expect(sync(body)).to contain_exactly(
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-0", start_at: Time.parse("2018-01-01 00:00:00Z"), end_at: nil),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-1", start_at: Time.parse("2019-01-01 00:00:00Z"), end_at: nil),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-2", start_at: Time.parse("2020-01-01 00:00:00Z"), end_at: nil),
        )
      end

      it "deletes future, unmodified recurring events" do
        body1 = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART:20180101T000000Z
          RRULE:FREQ=YEARLY;UNTIL=20230101T000000Z
          END:VEVENT
        ICAL
        body2 = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART:20180101T000000Z
          RRULE:FREQ=YEARLY;UNTIL=20210101T000000Z
          END:VEVENT
        ICAL

        req = stub_request(:get, "https://feed.me").
          and_return(
            {status: 200, headers: {"Content-Type" => "text/calendar"}, body: body1},
            {status: 200, headers: {"Content-Type" => "text/calendar"}, body: body2},
          )
        cal_row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")

        Timecop.freeze("2022-06-06") do
          svc.sync_row(cal_row)
        end
        events1 = event_svc.admin_dataset(&:all)
        expect(events1).to contain_exactly(
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-0", start_at: Time.parse("2018-01-01 00:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-1", start_at: Time.parse("2019-01-01 00:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-2", start_at: Time.parse("2020-01-01 00:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-3", start_at: Time.parse("2021-01-01 00:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-4", start_at: Time.parse("2022-01-01 00:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-5", start_at: Time.parse("2023-01-01 00:00:00Z")),
        )

        Timecop.freeze("2022-06-06") do
          svc.sync_row(cal_row)
        end
        events2 = event_svc.admin_dataset(&:all)
        expect(events2).to contain_exactly(
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-0", start_at: Time.parse("2018-01-01 00:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-1", start_at: Time.parse("2019-01-01 00:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-2", start_at: Time.parse("2020-01-01 00:00:00Z")),
          hash_including(compound_identity: "abc-c7614cff-3549-4a00-9152-d25cc1fe077d-3", start_at: Time.parse("2021-01-01 00:00:00Z")),
        )

        expect(req).to have_been_made.times(2)
      end

      it "deletes everything if the event does not recur" do
        body1 = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART:20180101T000000Z
          RRULE:FREQ=YEARLY;UNTIL=20230101T000000Z
          END:VEVENT
        ICAL
        body2 = <<~ICAL
          BEGIN:VEVENT
          SUMMARY:Abraham Lincoln
          UID:c7614cff-3549-4a00-9152-d25cc1fe077d
          DTSTART:20180101T000000Z
          RRULE:FREQ=YEARLY;UNTIL=20100101T000000Z
          END:VEVENT
        ICAL

        req = stub_request(:get, "https://feed.me").
          and_return(
            {status: 200, headers: {"Content-Type" => "text/calendar"}, body: body1},
            {status: 200, headers: {"Content-Type" => "text/calendar"}, body: body2},
          )
        cal_row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")

        Timecop.freeze("2022-06-06") do
          svc.sync_row(cal_row)
        end
        events1 = event_svc.admin_dataset(&:all)
        expect(events1).to have_length(6)

        Timecop.freeze("2022-06-06") do
          svc.sync_row(cal_row)
        end
        events2 = event_svc.admin_dataset(&:all)
        expect(events2).to be_empty

        expect(req).to have_been_made.times(2)
      end

      it "handles exception dates via recurrence-id field" do
        body1 = <<~ICAL
          BEGIN:VCALENDAR
          PRODID:-//Google Inc//Google Calendar 70.9054//EN
          VERSION:2.0
          BEGIN:VEVENT
          DTSTART;TZID=America/New_York:20230623T163000
          DTEND;TZID=America/New_York:20230623T170000
          RRULE:FREQ=DAILY;COUNT=4
          DTSTAMP:20230623T215026Z
          UID:73k3lgpbrb53fvdlv4m4jq9a5e@google.com
          CREATED:20230623T214717Z
          LAST-MODIFIED:20230623T214935Z
          SEQUENCE:0
          STATUS:CONFIRMED
          SUMMARY:Test Recur
          TRANSP:OPAQUE
          END:VEVENT
          END:VCALENDAR
        ICAL
        body2 = <<~ICAL
          BEGIN:VCALENDAR
          PRODID:-//Google Inc//Google Calendar 70.9054//EN
          VERSION:2.0
          BEGIN:VEVENT
          DTSTART;TZID=America/New_York:20230623T163000
          DTEND;TZID=America/New_York:20230623T170000
          RRULE:FREQ=DAILY;COUNT=4
          DTSTAMP:20230623T215026Z
          UID:73k3lgpbrb53fvdlv4m4jq9a5e@google.com
          CREATED:20230623T214717Z
          LAST-MODIFIED:20230623T214935Z
          SEQUENCE:0
          STATUS:CONFIRMED
          SUMMARY:Test Recur
          TRANSP:OPAQUE
          END:VEVENT
          BEGIN:VEVENT
          DTSTART;TZID=America/New_York:20230624T163000
          DTEND;TZID=America/New_York:20230624T171500
          DTSTAMP:20230623T215026Z
          UID:73k3lgpbrb53fvdlv4m4jq9a5e@google.com
          RECURRENCE-ID;TZID=America/New_York:20230624T163000
          CREATED:20230623T214717Z
          LAST-MODIFIED:20230623T214935Z
          SEQUENCE:0
          STATUS:CONFIRMED
          SUMMARY:Test Recur - Exception
          TRANSP:OPAQUE
          END:VEVENT
          END:VCALENDAR
        ICAL
        req = stub_request(:get, "https://feed.me").
          and_return(
            {status: 200, headers: {"Content-Type" => "text/calendar"}, body: body1},
            {status: 200, headers: {"Content-Type" => "text/calendar"}, body: body2},
          )
        cal_row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")

        Timecop.freeze("2023-06-20") do
          svc.sync_row(cal_row)
        end
        events1 = event_svc.admin_dataset { |ds| ds.select(:compound_identity, :start_at, :end_at).all }
        expect(events1).to contain_exactly(
          hash_including(
            compound_identity: "abc-73k3lgpbrb53fvdlv4m4jq9a5e@google.com-0",
            start_at: match_time("2023-06-23 20:30:00 +0000"),
            end_at: match_time("2023-06-23 21:00:00 +0000"),
          ),
          hash_including(
            compound_identity: "abc-73k3lgpbrb53fvdlv4m4jq9a5e@google.com-1",
            start_at: match_time("2023-06-24 20:30:00 +0000"),
            end_at: match_time("2023-06-24 21:00:00 +0000"),
          ),
          hash_including(
            compound_identity: "abc-73k3lgpbrb53fvdlv4m4jq9a5e@google.com-2",
            start_at: match_time("2023-06-25 20:30:00 +0000"),
            end_at: match_time("2023-06-25 21:00:00 +0000"),
          ),
          hash_including(
            compound_identity: "abc-73k3lgpbrb53fvdlv4m4jq9a5e@google.com-3",
            start_at: match_time("2023-06-26 20:30:00 +0000"),
            end_at: match_time("2023-06-26 21:00:00 +0000"),
          ),
        )

        Timecop.freeze("2022-06-06") do
          svc.sync_row(cal_row)
        end
        events2 = event_svc.admin_dataset { |ds| ds.select(:compound_identity, :start_at, :end_at).all }
        expect(events2).to contain_exactly(
          hash_including(
            compound_identity: "abc-73k3lgpbrb53fvdlv4m4jq9a5e@google.com-0",
            start_at: match_time("2023-06-23 20:30:00 +0000"),
            end_at: match_time("2023-06-23 21:00:00 +0000"),
          ),
          # This is the modified event, with a new end time (9:15)
          hash_including(
            compound_identity: "abc-73k3lgpbrb53fvdlv4m4jq9a5e@google.com-1",
            start_at: match_time("2023-06-24 20:30:00 +0000"),
            end_at: match_time("2023-06-24 21:15:00 +0000"),
          ),
          hash_including(
            compound_identity: "abc-73k3lgpbrb53fvdlv4m4jq9a5e@google.com-2",
            start_at: match_time("2023-06-25 20:30:00 +0000"),
            end_at: match_time("2023-06-25 21:00:00 +0000"),
          ),
          hash_including(
            compound_identity: "abc-73k3lgpbrb53fvdlv4m4jq9a5e@google.com-3",
            start_at: match_time("2023-06-26 20:30:00 +0000"),
            end_at: match_time("2023-06-26 21:00:00 +0000"),
          ),
        )

        expect(req).to have_been_made.times(2)
      end

      it "handles recurrence-id datetimes that do not match any RRULE" do
        body = <<~ICAL
          BEGIN:VCALENDAR
          PRODID:-//Google Inc//Google Calendar 70.9054//EN
          VERSION:2.0
          BEGIN:VEVENT
          CREATED:20160921T163517Z
          DTEND;TZID=America/New_York:20160923T200000
          DTSTAMP:20161111T235102Z
          DTSTART;TZID=America/New_York:20160923T190000
          LAST-MODIFIED:20160921T163518Z
          RRULE:FREQ=WEEKLY;UNTIL=20161007T230000Z
          SEQUENCE:0
          SUMMARY:Boys MA
          UID:2A389DBC-C85E-4A98-8817-8F5C0059DEB6
          END:VEVENT
          BEGIN:VEVENT
          CREATED:20161111T232837Z
          DTEND;TZID=America/New_York:20161111T200000
          DTSTAMP:20161111T235102Z
          DTSTART;TZID=America/New_York:20161111T190000
          LAST-MODIFIED:20161111T232837Z
          RECURRENCE-ID;TZID=America/New_York:20161111T190000
          SEQUENCE:0
          SUMMARY:Boys MA
          UID:2A389DBC-C85E-4A98-8817-8F5C0059DEB6
          END:VEVENT
          END:VCALENDAR
        ICAL
        req = stub_request(:get, "https://feed.me").
          and_return(status: 200, headers: {"Content-Type" => "text/calendar"}, body:)
        cal_row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")

        event_svc.admin_dataset do |ds|
          # Make sure this gets deleted
          ds.insert(
            data: "{}",
            compound_identity: "abc-2A389DBC-C85E-4A98-8817-8F5C0059DEB6-4",
            calendar_external_id: "abc",
            recurring_event_id: "2A389DBC-C85E-4A98-8817-8F5C0059DEB6",
            recurring_event_sequence: 4,
          )
        end

        svc.sync_row(cal_row)
        expect(req).to have_been_made

        events = event_svc.admin_dataset(&:all)
        expect(events).to contain_exactly(
          include(
            compound_identity: "abc-2A389DBC-C85E-4A98-8817-8F5C0059DEB6-0",
            start_at: match_time("2016-09-23 23:00:00 +0000"),
            end_at: match_time("2016-09-24 00:00:00 +0000"),
          ),
          include(
            compound_identity: "abc-2A389DBC-C85E-4A98-8817-8F5C0059DEB6-1",
            start_at: match_time("2016-09-30 23:00:00 +0000"),
            end_at: match_time("2016-10-01 00:00:00 +0000"),
          ),
          include(
            compound_identity: "abc-2A389DBC-C85E-4A98-8817-8F5C0059DEB6-2",
            start_at: match_time("2016-10-07 23:00:00 +0000"),
            end_at: match_time("2016-10-08 00:00:00 +0000"),
          ),
          include(
            compound_identity: "abc-2A389DBC-C85E-4A98-8817-8F5C0059DEB6-3",
            start_at: match_time("2016-11-12 00:00:00 +0000"),
            end_at: match_time("2016-11-12 01:00:00 +0000"),
            recurring_event_id: "2A389DBC-C85E-4A98-8817-8F5C0059DEB6",
            recurring_event_sequence: 3,
          ),
        )
      end

      it "handles recurrence-id that does not have a corresponding UID" do
        body = <<~ICAL
          BEGIN:VCALENDAR
          PRODID:-//Google Inc//Google Calendar 70.9054//EN
          VERSION:2.0
          BEGIN:VEVENT
          DTEND;VALUE=DATE:20110215
          DTSTAMP:20111029T235747Z
          DTSTART;VALUE=DATE:20110214
          LAST-MODIFIED:20110131T011428Z
          RECURRENCE-ID:20110214T000000
          SEQUENCE:0
          STATUS:CONFIRMED
          SUMMARY:Valentines day!
          TRANSP:OPAQUE
          UID:09490091-F30F-4391-AEB4-945A3EAFC2D1
          BEGIN:VALARM
          ACTION:DISPLAY
          DESCRIPTION:Event reminder
          TRIGGER;VALUE=DURATION:-P2D
          X-WR-ALARMUID:F25C19ED-F345-4B11-A71C-6F9B354ABD41
          END:VALARM
          END:VEVENT
          END:VCALENDAR
        ICAL
        req = stub_request(:get, "https://feed.me").
          and_return(status: 200, headers: {"Content-Type" => "text/calendar"}, body:)
        cal_row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")

        svc.sync_row(cal_row)
        expect(req).to have_been_made

        events = event_svc.admin_dataset(&:all)
        expect(events).to contain_exactly(
          include(
            compound_identity: "abc-09490091-F30F-4391-AEB4-945A3EAFC2D1",
            start_date: Date.parse("20110214"),
            end_date: Date.parse("20110215"),
            recurring_event_id: nil,
            recurring_event_sequence: nil,
          ),
        )
      end

      it "handles times without zones" do
        body = <<~ICAL
          BEGIN:VCALENDAR
          PRODID:-//Google Inc//Google Calendar 70.9054//EN
          VERSION:2.0
          BEGIN:VEVENT
          CREATED:20161111T232837Z
          DTEND:20161111T200000
          DTSTAMP:20161111T235102Z
          DTSTART:20161111T190000
          LAST-MODIFIED:20161111T232837Z
          SEQUENCE:0
          SUMMARY:Boys MA
          UID:missingtz
          END:VEVENT
          BEGIN:VEVENT
          CREATED:20161111T232837Z
          DTEND:20161111T200000Z
          DTSTAMP:20161111T235102Z
          DTSTART:20161111T190000Z
          LAST-MODIFIED:20161111T232837Z
          SEQUENCE:0
          SUMMARY:Boys MA
          UID:hastz
          END:VEVENT
          END:VCALENDAR
        ICAL
        req = stub_request(:get, "https://feed.me").
          and_return(status: 200, headers: {"Content-Type" => "text/calendar"}, body:)
        cal_row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")

        svc.sync_row(cal_row)
        expect(req).to have_been_made

        events = event_svc.admin_dataset(&:all)
        expect(events).to contain_exactly(
          include(
            compound_identity: "abc-missingtz",
            start_at: match_time("2016-11-11 19:00:00 +0000"),
            end_at: match_time("2016-11-11 20:00:00 +0000"),
            missing_timezone: true,
          ),
          include(
            compound_identity: "abc-hastz",
            start_at: match_time("2016-11-11 19:00:00 +0000"),
            end_at: match_time("2016-11-11 20:00:00 +0000"),
            missing_timezone: false,
          ),
        )
      end

      it "ignores events with backwards start/end times because who knows what these are" do
        body = <<~ICAL
          BEGIN:VEVENT
          CREATED:20231211T152742Z
          DTEND;TZID=America/Indianapolis:20240122T123000
          DTSTAMP:20231214T143743Z
          DTSTART;TZID=America/Indianapolis:20240122T160000
          EXDATE;TZID=America/Indianapolis:20231218T110000
          EXDATE;TZID=America/Indianapolis:20231220T110000
          EXDATE;TZID=America/Indianapolis:20231225T110000
          LAST-MODIFIED:20231214T143742Z
          RRULE:FREQ=WEEKLY;BYDAY=MO,WE
          SEQUENCE:0
          SUMMARY:Abe Lincoln
          UID:77082075-30B2-4A5D-AB3C-F65F73C1E90E
          END:VEVENT
        ICAL
        expect(sync(body)).to contain_exactly(
          hash_including(compound_identity: "abc-77082075-30B2-4A5D-AB3C-F65F73C1E90E"),
        )
      end

      it "does not project events before the year 1000 since it is likely a misconfiguration" do
        body = <<~ICAL
          BEGIN:VEVENT
          CREATED:20231211T152742Z
          DTEND;TZID=America/Indianapolis:20240122T123000
          DTSTAMP:20231214T143743Z
          DTSTART;TZID=America/Indianapolis:00210122T110000
          EXDATE;TZID=America/Indianapolis:20231218T110000
          EXDATE;TZID=America/Indianapolis:20231220T110000
          EXDATE;TZID=America/Indianapolis:20231225T110000
          LAST-MODIFIED:20231214T143742Z
          RRULE:FREQ=WEEKLY;BYDAY=MO,WE
          SEQUENCE:0
          SUMMARY:Abe Lincoln
          UID:77082075-30B2-4A5D-AB3C-F65F73C1E90E
          END:VEVENT
        ICAL
        expect(sync(body)).to contain_exactly(
          hash_including(compound_identity: "abc-77082075-30B2-4A5D-AB3C-F65F73C1E90E"),
        )
      end

      it "does not project events older than the configured time" do
        body = <<~ICAL
          BEGIN:VEVENT
          CREATED:20231211T152742Z
          DTEND;TZID=America/Indianapolis:19240122T123000
          DTSTAMP:20231214T143743Z
          DTSTART;TZID=America/Indianapolis:19240122T110000
          EXDATE;TZID=America/Indianapolis:20231218T110000
          EXDATE;TZID=America/Indianapolis:20231220T110000
          EXDATE;TZID=America/Indianapolis:20231225T110000
          LAST-MODIFIED:20231214T143742Z
          RRULE:FREQ=WEEKLY;BYDAY=MO,WE
          SEQUENCE:0
          SUMMARY:Abe Lincoln
          UID:77082075-30B2-4A5D-AB3C-F65F73C1E90E
          END:VEVENT
        ICAL
        got = sync(body)
        expect(got.first).to include(compound_identity: "abc-77082075-30B2-4A5D-AB3C-F65F73C1E90E-6881", start_at: match_time("1990-01-01 16:00:00Z"))
        expect(got.last).to include(start_at: be > 1.month.ago)
      end

      it "yields invalid dates as single events" do
        body = <<~ICAL
          BEGIN:VEVENT
          CREATED:20231211T152742Z
          DTEND;TZID=America/Indianapolis:15240122T123000
          DTSTAMP:20231214T143743Z
          DTSTART;TZID=America/Indianapolis:15240122T110000
          EXDATE;TZID=America/Indianapolis:20231218T110000
          EXDATE;TZID=America/Indianapolis:20231220T110000
          EXDATE;TZID=America/Indianapolis:20231225T110000
          LAST-MODIFIED:20231214T143742Z
          RRULE:FREQ=WEEKLY;BYDAY=MO,WE
          SEQUENCE:0
          SUMMARY:Abe Lincoln
          UID:77082075-30B2-4A5D-AB3C-F65F73C1E90E
          END:VEVENT
        ICAL
        expect(sync(body)).to contain_exactly(hash_including(compound_identity: "abc-77082075-30B2-4A5D-AB3C-F65F73C1E90E"))
      end

      describe "IceCube fixes" do
        it "handles BYSETPOS=2" do
          # See https://github.com/ice-cube-ruby/ice_cube/pull/449
          body = <<~ICAL
            BEGIN:VEVENT
            SUMMARY:Bug Person
            UID:c7614cff-3549-4a00-9152-d25cc1fe077d
            DTSTART:20230711T120000Z
            DTEND:20230711T130000Z
            RRULE:FREQ=MONTHLY;BYSETPOS=2;BYDAY=TU;INTERVAL=1;COUNT=4
            END:VEVENT
          ICAL
          expect(sync(body)).to contain_exactly(
            hash_including(start_at: Time.parse("2023-07-11 12:00:00Z"), end_at: Time.parse("2023-07-11 13:00:00Z"), recurring_event_sequence: 0),
            hash_including(start_at: Time.parse("2023-08-08 12:00:00Z"), end_at: Time.parse("2023-08-08 13:00:00Z"), recurring_event_sequence: 1),
            hash_including(start_at: Time.parse("2023-09-12 12:00:00Z"), end_at: Time.parse("2023-09-12 13:00:00Z"), recurring_event_sequence: 2),
            hash_including(start_at: Time.parse("2023-10-10 12:00:00Z"), end_at: Time.parse("2023-10-10 13:00:00Z"), recurring_event_sequence: 3),
          )
        end
      end
    end

    it "handles RRULE with FREQ=WEEKLY and BYMONTHDAY" do
      body = <<~ICS
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        CREATED:20230819T112212Z
        DTEND;VALUE=DATE:20230907
        DTSTAMP:20230819T112238Z
        DTSTART;VALUE=DATE:20230906
        RRULE:FREQ=WEEKLY;UNTIL=20231115;INTERVAL=2;BYMONTHDAY=4
        SEQUENCE:0
        X-Comment:BYMONTHDAY with FREQ=WEEKLY makes no sense,
          Apple just seems to use every-2-weeks,
          so that's what we'll do here.
        SUMMARY:Circles
        UID:bymonthday-with-freq-weekly
        END:VEVENT
        BEGIN:VEVENT
        CREATED:20230819T112212Z
        DTEND;VALUE=DATE:20230907
        DTSTAMP:20230819T112238Z
        DTSTART;VALUE=DATE:20230906
        RRULE:FREQ=WEEKLY;UNTIL=20231001;INTERVAL=2;BYMONTHDAY=4,26,5
        SEQUENCE:0
        X-Comment:Same as above but with multiple BYMONTHDAY
        SUMMARY:Circles
        UID:multibymonthday-with-freq-weekly
        END:VEVENT
        END:VCALENDAR
      ICS
      req = stub_request(:get, "https://feed.me").
        and_return(status: 200, headers: {"Content-Type" => "text/calendar"}, body:)
      row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
      svc.sync_row(row)
      expect(req).to have_been_made
      expect(event_svc.admin_dataset(&:all)).to contain_exactly(
        include(uid: "bymonthday-with-freq-weekly-0", start_date: Date.new(2023, 9, 6)),
        include(uid: "bymonthday-with-freq-weekly-1", start_date: Date.new(2023, 9, 20)),
        include(uid: "bymonthday-with-freq-weekly-2", start_date: Date.new(2023, 10, 4)),
        include(uid: "bymonthday-with-freq-weekly-3", start_date: Date.new(2023, 10, 18)),
        include(uid: "bymonthday-with-freq-weekly-4", start_date: Date.new(2023, 11, 1)),
        include(uid: "bymonthday-with-freq-weekly-5", start_date: Date.new(2023, 11, 15)),
        include(uid: "multibymonthday-with-freq-weekly-0", start_date: Date.new(2023, 9, 6)),
        include(uid: "multibymonthday-with-freq-weekly-1", start_date: Date.new(2023, 9, 20)),
      )
    end

    it "handles when the server sends gzip even though we do not want it" do
      body = <<~ICAL
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        SUMMARY:Abraham Lincoln
        UID:c7614cff-3549-4a00-9152-d25cc1fe077d
        STATUS:CONFIRMED
        DTSTART:20080212
        DTEND:20080213
        DTSTAMP:20150421T141403
        END:VEVENT
        END:VCALENDAR
      ICAL
      resp = {
        status: 200,
        headers: {"Content-Type" => "text/calendar; charset=UTF-8", "Content-Encoding" => "gzip"},
        body: ActiveSupport::Gzip.compress(body),
      }
      req = stub_request(:get, "https://feed.me").
        with { |r| ["", "gzip;q=1.0,deflate;q=0.6,identity;q=0.3"].include?(r.headers["Accept-Encoding"]) }.
        and_return(resp, resp)
      row = insert_calendar_row(ics_url: "https://feed.me", external_id: "abc")
      svc.sync_row(row)
      expect(svc.admin_dataset(&:first)).to include(last_synced_at: match_time(:now))
      expect(req).to have_been_made # .times(2)
      expect(event_svc.admin_dataset(&:all)).to have_length(1)
    end
  end

  # Based on https://github.com/icalendar/icalendar/blob/main/spec/parser_spec.rb
  describe "icalendar parser tests" do
    let(:source) { File.open(Webhookdb::SpecHelpers::TEST_DATA_DIR + "icalendar" + fn) }
    let(:replicator) { described_class.new(nil) }
    let(:upserter) { described_class::Upserter.new(replicator, "1") }

    def events
      arr = []
      described_class::EventProcessor.new(source, upserter).each_feed_event { |a| arr << a }
      arr
    end

    context "single_event.ics" do
      let(:fn) { "single_event.ics" }

      it "returns an array of calendars" do
        parsed = events
        expect(parsed).to contain_exactly(
          {
            "DTSTAMP" => {"v" => "20050118T211523Z"},
            "UID" => {"v" => "bsuidfortestabc123"},
            "DTSTART" => {"v" => "20050120T170000", "TZID" => "US-Mountain"},
            "DTEND" => {"v" => "20050120T184500", "TZID" => "US-Mountain"},
            "CLASS" => {"v" => "PRIVATE"},
            "GEO" => {"v" => "37.386013;-122.0829322"},
            "ORGANIZER" => {"v" => "mailto:joebob@random.net", "CN" => "Joe Bob: Magician"},
            "PRIORITY" => {"v" => "2"},
            "SUMMARY" => {"v" => "This is a really long summary to test the method of unfolding lines\\, so I'm just going to make it a whole bunch of lines. With a twist: a \"ö\" takes up multiple bytes\\, and should be wrapped to the next line."},
            "ATTACH" => [{"v" => "http://bush.sucks.org/impeach/him.rhtml"}, {"v" => "http://corporations-dominate.existence.net/why.rhtml"}],
            "RDATE" => [{"v" => "20050121T170000,20050122T170000", "TZID" => "US-Mountain"}],
            "X-TEST-COMPONENT" => {"v" => "Shouldn't double double quotes", "QTEST" => "Hello, World"},
          },
        )
      end
    end

    context "event.ics" do
      let(:fn) { "event.ics" }

      it "returns an array of events" do
        parsed = events
        expect(parsed).to contain_exactly(
          {
            "DTSTAMP" => {"v" => "20050118T211523Z"},
            "UID" => {"v" => "bsuidfortestabc123"},
            "DTSTART" => {"v" => "20050120T170000", "TZID" => "US-Mountain"},
            "DTEND" => {"v" => "20050120T184500", "TZID" => "US-Mountain"},
            "CLASS" => {"v" => "PRIVATE"},
            "GEO" => {"v" => "37.386013;-122.0829322"},
            "ORGANIZER" => {"v" => "mailto:joebob@random.net"},
            "PRIORITY" => {"v" => "2"},
            "SUMMARY" => {"v" => "This is a really long summary to test the method of unfolding lines\\, so I'm just going to make it a whole bunch of lines."},
            "ATTACH" => [{"v" => "http://bush.sucks.org/impeach/him.rhtml"}, {"v" => "http://corporations-dominate.existence.net/why.rhtml"}],
            "RDATE" => [{"v" => "20050121T170000,20050122T170000", "TZID" => "US-Mountain"}],
            "X-TEST-COMPONENT" => {"v" => "Shouldn't double double quotes", "QTEST" => "Hello, World"},
          },
        )
      end
    end

    context "events.ics" do
      let(:fn) { "two_events.ics" }

      it "returns an array of events" do
        parsed = events
        expect(parsed).to contain_exactly(
          hash_including("UID" => {"v" => "bsuidfortestabc123"}),
          {
            "DTSTAMP" => {"v" => "20110118T211523Z"},
            "UID" => {"v" => "uid-1234-uid-4321"},
            "DTSTART" => {"v" => "20110120T170000", "TZID" => "US-Mountain"},
            "DTEND" => {"v" => "20110120T184500", "TZID" => "US-Mountain"},
            "CLASS" => {"v" => "PRIVATE"},
            "GEO" => {"v" => "37.386013;-122.0829322"},
            "ORGANIZER" => {"v" => "mailto:jmera@jmera.human"},
            "PRIORITY" => {"v" => "2"},
            "SUMMARY" => {"v" => "This is a very short summary."},
            "RDATE" => [{"v" => "20110121T170000,20110122T170000", "TZID" => "US-Mountain"}],
          },
        )
      end
    end

    context "tzid_search.ics" do
      let(:fn) { "tzid_search.ics" }

      it "correctly sets the weird tzid" do
        parsed = events
        expect(parsed).to contain_exactly(
          hash_including(
            "DTEND" => {"v" => "20180104T130000", "TZID" => "(GMT-05:00) Eastern Time (US & Canada)"},
            "RRULE" => {"v" => "FREQ=WEEKLY;INTERVAL=1"},
            "SUMMARY" => {"v" => "Recurring on Wed"},
            "DTSTART" => {"v" => "20180104T100000", "TZID" => "(GMT-05:00) Eastern Time (US & Canada)"},
            "DTSTAMP" => {"v" => "20120104T231637Z"},
          ),
        )
      end
    end

    context "missing_required.ics" do
      let(:fn) { "missing_required.ics" }

      it "skips and warns about invalid items" do
        logs = capture_logs_from(replicator.logger, level: :warn, formatter: :json) do
          parsed = events
          expect(parsed).to contain_exactly(
            hash_including("SUMMARY" => {"v" => "Missing DTSTAMP"}),
            hash_including("SUMMARY" => {"v" => "Missing nothing"}),
          )
        end
        expect(logs).to contain_exactly(
          include_json(
            level: "warn",
            name: "Webhookdb::Replicator::IcalendarCalendarV1",
            message: "invalid_vevent_hash",
            context: {
              vevent_uids: ["4BCDDF02-458B-4D52-BC87-86ED43B0BF22", "[missing]", "ev1"],
            },
          ),
        )
      end
    end

    describe "#parse with bad line" do
      let(:fn) { "single_event_bad_line.ics" }

      it "uses nil" do
        parsed = events
        expect(parsed).to contain_exactly(
          hash_including(
            "UID" => {"v" => "bsuidfortestabc123"},
            "X-NO-VALUE" => {"v" => nil},
          ),
        )
      end
    end

    describe "missing date value parameter" do
      let(:fn) { "single_event_bad_dtstart.ics" }

      it "falls back to date type for dtstart" do
        parsed = events
        expect(parsed).to contain_exactly(hash_including("DTSTART" => {"v" => "20050120"}))
      end
    end
  end
end
# rubocop:enable Layout/LineLength
