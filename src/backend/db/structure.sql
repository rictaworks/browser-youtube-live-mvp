SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: admin_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_actions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    action character varying NOT NULL,
    target character varying,
    detail character varying,
    occurred_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: broadcast_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.broadcast_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    broadcast_id uuid NOT NULL,
    occurred_at timestamp(6) without time zone NOT NULL,
    event_type character varying NOT NULL,
    detail character varying,
    CONSTRAINT chk_broadcast_events_event_type CHECK (((event_type)::text = ANY (ARRAY['accepted'::text, 'verified'::text, 'probe_done'::text, 'provision_started'::text, 'provision_done'::text, 'publish_started'::text, 'live_confirmed'::text, 'source_added'::text, 'source_lost'::text, 'fallback_switched'::text, 'bitrate_down'::text, 'bitrate_up'::text, 'video_dropped'::text, 'degraded_started'::text, 'degraded_cleared'::text, 'interrupted'::text, 'resumed'::text, 'throttle_directed'::text, 'keyframe_requested'::text, 'youtube_warning'::text, 'time_limit_notice'::text, 'ended'::text, 'settlement_succeeded'::text, 'settlement_failed'::text])))
);


--
-- Name: broadcasts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.broadcasts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    daily_usage_id uuid NOT NULL,
    state character varying DEFAULT 'reserved'::character varying NOT NULL,
    end_reason character varying,
    settlement_state character varying DEFAULT 'none'::character varying NOT NULL,
    settlement_attempts integer DEFAULT 0 NOT NULL,
    usage_date date NOT NULL,
    quota_date date NOT NULL,
    prep_reserved_units integer DEFAULT 0 NOT NULL,
    settle_reserved_units integer DEFAULT 0 NOT NULL,
    attempt_counted boolean DEFAULT false NOT NULL,
    resume_count integer DEFAULT 0 NOT NULL,
    sent_bytes bigint DEFAULT 0 NOT NULL,
    profile character varying,
    publisher_epoch integer DEFAULT 0 NOT NULL,
    pending_title character varying,
    scheduled_start_at timestamp(6) without time zone,
    privacy_status character varying NOT NULL,
    made_for_kids boolean NOT NULL,
    youtube_broadcast_id character varying,
    youtube_stream_id character varying,
    bound boolean DEFAULT false NOT NULL,
    allowance_consumed boolean DEFAULT false NOT NULL,
    accepted_at timestamp(6) without time zone NOT NULL,
    provisioned_at timestamp(6) without time zone,
    publish_started_at timestamp(6) without time zone,
    live_at timestamp(6) without time zone,
    interrupted_at timestamp(6) without time zone,
    last_heartbeat_at timestamp(6) without time zone,
    last_checked_at timestamp(6) without time zone,
    ended_at timestamp(6) without time zone,
    CONSTRAINT chk_broadcasts_end_reason CHECK (((end_reason IS NULL) OR ((end_reason)::text = ANY (ARRAY['user_stop'::text, 'time_limit'::text, 'connection_lost'::text, 'youtube_ended'::text, 'authorization_revoked'::text, 'admin_stop'::text, 'start_timeout'::text, 'confirm_timeout'::text, 'prepare_failed'::text, 'prior_unsettled'::text, 'insufficient_bandwidth'::text, 'user_cancel'::text, 'relay_disconnect'::text])))),
    CONSTRAINT chk_broadcasts_pending_title_lifecycle CHECK (((pending_title IS NULL) OR ((youtube_broadcast_id IS NULL) AND ((state)::text <> 'ended'::text)))),
    CONSTRAINT chk_broadcasts_prep_reserved_units_non_negative CHECK ((prep_reserved_units >= 0)),
    CONSTRAINT chk_broadcasts_privacy_status CHECK (((privacy_status)::text = ANY (ARRAY['public'::text, 'unlisted'::text, 'private'::text]))),
    CONSTRAINT chk_broadcasts_profile CHECK (((profile IS NULL) OR ((profile)::text = ANY (ARRAY['720p'::text, '480p'::text])))),
    CONSTRAINT chk_broadcasts_publisher_epoch_non_negative CHECK ((publisher_epoch >= 0)),
    CONSTRAINT chk_broadcasts_resume_count_non_negative CHECK ((resume_count >= 0)),
    CONSTRAINT chk_broadcasts_sent_bytes_non_negative CHECK ((sent_bytes >= 0)),
    CONSTRAINT chk_broadcasts_settle_reserved_units_non_negative CHECK ((settle_reserved_units >= 0)),
    CONSTRAINT chk_broadcasts_settlement_attempts_non_negative CHECK ((settlement_attempts >= 0)),
    CONSTRAINT chk_broadcasts_settlement_state CHECK (((settlement_state)::text = ANY (ARRAY['none'::text, 'pending'::text, 'settled'::text, 'abandoned'::text]))),
    CONSTRAINT chk_broadcasts_state CHECK (((state)::text = ANY (ARRAY['reserved'::text, 'awaiting_media'::text, 'confirming'::text, 'live'::text, 'interrupted'::text, 'ended'::text])))
);


--
-- Name: daily_usages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_usages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    usage_date date NOT NULL,
    consumed_count integer DEFAULT 0 NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    extra_grants integer DEFAULT 0 NOT NULL,
    CONSTRAINT chk_daily_usages_attempt_count_non_negative CHECK ((attempt_count >= 0)),
    CONSTRAINT chk_daily_usages_consumed_count_non_negative CHECK ((consumed_count >= 0)),
    CONSTRAINT chk_daily_usages_extra_grants_non_negative CHECK ((extra_grants >= 0))
);


--
-- Name: deletion_holds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deletion_holds (
    sub_digest character varying NOT NULL,
    hold_usage_date date NOT NULL
);


--
-- Name: health_samples; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.health_samples (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    broadcast_id uuid NOT NULL,
    sampled_at timestamp(6) without time zone NOT NULL,
    sent_kbps integer,
    target_kbps integer,
    backlog_ms integer,
    dropped_video_frames integer,
    relay_out_kbps integer,
    state character varying
);


--
-- Name: quota_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quota_days (
    quota_date date NOT NULL,
    used_units integer DEFAULT 0 NOT NULL,
    reserved_units integer DEFAULT 0 NOT NULL,
    common_used_units integer DEFAULT 0 NOT NULL,
    exhausted boolean DEFAULT false NOT NULL,
    CONSTRAINT chk_quota_days_common_used_units_non_negative CHECK ((common_used_units >= 0)),
    CONSTRAINT chk_quota_days_reserved_units_non_negative CHECK ((reserved_units >= 0)),
    CONSTRAINT chk_quota_days_used_units_non_negative CHECK ((used_units >= 0))
);


--
-- Name: quota_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quota_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    quota_date date NOT NULL,
    broadcast_id uuid,
    method character varying NOT NULL,
    units integer NOT NULL,
    result character varying NOT NULL,
    bucket character varying NOT NULL,
    called_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_quota_entries_bucket CHECK (((bucket)::text = ANY (ARRAY['prep'::text, 'settle'::text, 'common'::text]))),
    CONSTRAINT chk_quota_entries_result CHECK (((result)::text = ANY (ARRAY['ok'::text, 'error'::text]))),
    CONSTRAINT chk_quota_entries_units_non_negative CHECK ((units >= 0))
);


--
-- Name: relay_tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.relay_tickets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    broadcast_id uuid NOT NULL,
    token_digest character varying NOT NULL,
    epoch integer NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    used_at timestamp(6) without time zone,
    CONSTRAINT chk_relay_tickets_epoch_non_negative CHECK ((epoch >= 0))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    last_used_at timestamp(6) without time zone NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL
);


--
-- Name: system_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_settings (
    key character varying NOT NULL,
    value character varying NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: transfer_months; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transfer_months (
    month character varying NOT NULL,
    sent_bytes bigint DEFAULT 0 NOT NULL,
    CONSTRAINT chk_transfer_months_month_format CHECK (((month)::text ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'::text)),
    CONSTRAINT chk_transfer_months_sent_bytes_non_negative CHECK ((sent_bytes >= 0))
);


--
-- Name: usage_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.usage_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    occurred_at timestamp(6) without time zone NOT NULL,
    event_type character varying NOT NULL,
    reason_code character varying,
    bucket character varying,
    browser_class character varying,
    CONSTRAINT chk_usage_events_event_type CHECK (((event_type)::text = ANY (ARRAY['login_started'::text, 'login_completed'::text, 'connect_started'::text, 'connect_completed'::text, 'connect_failed'::text, 'capability_detected'::text, 'source_granted'::text, 'source_denied'::text, 'start_requested'::text, 'start_rejected'::text, 'line_measured'::text, 'prepared'::text, 'live_confirmed'::text, 'degraded'::text, 'reconnect_started'::text, 'reconnect_succeeded'::text, 'broadcast_ended'::text, 'watch_url_copied'::text, 'disconnected'::text, 'account_deleted'::text])))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    google_sub character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    last_login_at timestamp(6) without time zone NOT NULL
);


--
-- Name: youtube_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.youtube_connections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    state character varying NOT NULL,
    refresh_token_ciphertext text NOT NULL,
    youtube_stream_id character varying,
    stream_verified_at timestamp(6) without time zone,
    connected_at timestamp(6) without time zone NOT NULL,
    last_verified_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT chk_youtube_connections_state CHECK (((state)::text = ANY (ARRAY['connected'::text, 'live_not_enabled'::text, 'revoked'::text])))
);


--
-- Name: admin_actions admin_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_actions
    ADD CONSTRAINT admin_actions_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: broadcast_events broadcast_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.broadcast_events
    ADD CONSTRAINT broadcast_events_pkey PRIMARY KEY (id);


--
-- Name: broadcasts broadcasts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.broadcasts
    ADD CONSTRAINT broadcasts_pkey PRIMARY KEY (id);


--
-- Name: daily_usages daily_usages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_usages
    ADD CONSTRAINT daily_usages_pkey PRIMARY KEY (id);


--
-- Name: deletion_holds deletion_holds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deletion_holds
    ADD CONSTRAINT deletion_holds_pkey PRIMARY KEY (sub_digest);


--
-- Name: health_samples health_samples_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_samples
    ADD CONSTRAINT health_samples_pkey PRIMARY KEY (id);


--
-- Name: quota_days quota_days_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quota_days
    ADD CONSTRAINT quota_days_pkey PRIMARY KEY (quota_date);


--
-- Name: quota_entries quota_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quota_entries
    ADD CONSTRAINT quota_entries_pkey PRIMARY KEY (id);


--
-- Name: relay_tickets relay_tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relay_tickets
    ADD CONSTRAINT relay_tickets_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: system_settings system_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_settings
    ADD CONSTRAINT system_settings_pkey PRIMARY KEY (key);


--
-- Name: transfer_months transfer_months_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transfer_months
    ADD CONSTRAINT transfer_months_pkey PRIMARY KEY (month);


--
-- Name: usage_events usage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT usage_events_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: youtube_connections youtube_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.youtube_connections
    ADD CONSTRAINT youtube_connections_pkey PRIMARY KEY (id);


--
-- Name: idx_admin_actions_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_actions_occurred_at ON public.admin_actions USING btree (occurred_at);


--
-- Name: idx_broadcast_events_broadcast_id_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcast_events_broadcast_id_occurred_at ON public.broadcast_events USING btree (broadcast_id, occurred_at);


--
-- Name: idx_broadcast_events_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcast_events_occurred_at ON public.broadcast_events USING btree (occurred_at);


--
-- Name: idx_broadcast_events_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcast_events_user_id ON public.broadcast_events USING btree (user_id);


--
-- Name: idx_broadcasts_daily_usage_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcasts_daily_usage_id ON public.broadcasts USING btree (daily_usage_id);


--
-- Name: idx_broadcasts_ended_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcasts_ended_at ON public.broadcasts USING btree (ended_at);


--
-- Name: idx_broadcasts_one_unended_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_broadcasts_one_unended_per_user ON public.broadcasts USING btree (user_id) WHERE ((state)::text <> 'ended'::text);


--
-- Name: idx_broadcasts_settlement_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcasts_settlement_state ON public.broadcasts USING btree (settlement_state);


--
-- Name: idx_broadcasts_state_accepted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcasts_state_accepted_at ON public.broadcasts USING btree (state, accepted_at);


--
-- Name: idx_broadcasts_user_id_accepted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcasts_user_id_accepted_at ON public.broadcasts USING btree (user_id, accepted_at);


--
-- Name: idx_daily_usages_user_id_usage_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_daily_usages_user_id_usage_date ON public.daily_usages USING btree (user_id, usage_date);


--
-- Name: idx_health_samples_broadcast_id_sampled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_health_samples_broadcast_id_sampled_at ON public.health_samples USING btree (broadcast_id, sampled_at);


--
-- Name: idx_health_samples_sampled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_health_samples_sampled_at ON public.health_samples USING btree (sampled_at);


--
-- Name: idx_health_samples_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_health_samples_user_id ON public.health_samples USING btree (user_id);


--
-- Name: idx_quota_entries_broadcast_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quota_entries_broadcast_id ON public.quota_entries USING btree (broadcast_id);


--
-- Name: idx_quota_entries_quota_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quota_entries_quota_date ON public.quota_entries USING btree (quota_date);


--
-- Name: idx_relay_tickets_broadcast_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_relay_tickets_broadcast_id ON public.relay_tickets USING btree (broadcast_id);


--
-- Name: idx_relay_tickets_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_relay_tickets_expires_at ON public.relay_tickets USING btree (expires_at);


--
-- Name: idx_relay_tickets_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_relay_tickets_token_digest ON public.relay_tickets USING btree (token_digest);


--
-- Name: idx_relay_tickets_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_relay_tickets_user_id ON public.relay_tickets USING btree (user_id);


--
-- Name: idx_sessions_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_expires_at ON public.sessions USING btree (expires_at);


--
-- Name: idx_sessions_token_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_sessions_token_digest ON public.sessions USING btree (token_digest);


--
-- Name: idx_sessions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_user_id ON public.sessions USING btree (user_id);


--
-- Name: idx_usage_events_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_usage_events_user_id ON public.usage_events USING btree (user_id);


--
-- Name: idx_users_google_sub; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_users_google_sub ON public.users USING btree (google_sub);


--
-- Name: idx_youtube_connections_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_youtube_connections_user_id ON public.youtube_connections USING btree (user_id);


--
-- Name: broadcast_events fk_broadcast_events_broadcast_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.broadcast_events
    ADD CONSTRAINT fk_broadcast_events_broadcast_id FOREIGN KEY (broadcast_id) REFERENCES public.broadcasts(id) ON DELETE CASCADE;


--
-- Name: broadcast_events fk_broadcast_events_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.broadcast_events
    ADD CONSTRAINT fk_broadcast_events_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: broadcasts fk_broadcasts_daily_usage_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.broadcasts
    ADD CONSTRAINT fk_broadcasts_daily_usage_id FOREIGN KEY (daily_usage_id) REFERENCES public.daily_usages(id);


--
-- Name: broadcasts fk_broadcasts_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.broadcasts
    ADD CONSTRAINT fk_broadcasts_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: daily_usages fk_daily_usages_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_usages
    ADD CONSTRAINT fk_daily_usages_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: health_samples fk_health_samples_broadcast_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_samples
    ADD CONSTRAINT fk_health_samples_broadcast_id FOREIGN KEY (broadcast_id) REFERENCES public.broadcasts(id) ON DELETE CASCADE;


--
-- Name: health_samples fk_health_samples_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.health_samples
    ADD CONSTRAINT fk_health_samples_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: quota_entries fk_quota_entries_broadcast_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quota_entries
    ADD CONSTRAINT fk_quota_entries_broadcast_id FOREIGN KEY (broadcast_id) REFERENCES public.broadcasts(id) ON DELETE SET NULL;


--
-- Name: quota_entries fk_quota_entries_quota_date; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quota_entries
    ADD CONSTRAINT fk_quota_entries_quota_date FOREIGN KEY (quota_date) REFERENCES public.quota_days(quota_date);


--
-- Name: relay_tickets fk_relay_tickets_broadcast_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relay_tickets
    ADD CONSTRAINT fk_relay_tickets_broadcast_id FOREIGN KEY (broadcast_id) REFERENCES public.broadcasts(id) ON DELETE CASCADE;


--
-- Name: relay_tickets fk_relay_tickets_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relay_tickets
    ADD CONSTRAINT fk_relay_tickets_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: sessions fk_sessions_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_sessions_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: usage_events fk_usage_events_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.usage_events
    ADD CONSTRAINT fk_usage_events_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: youtube_connections fk_youtube_connections_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.youtube_connections
    ADD CONSTRAINT fk_youtube_connections_user_id FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261007160016'),
('20261007160015'),
('20261007160014'),
('20261007160013'),
('20261007160012'),
('20261007160011'),
('20261007160010'),
('20261007160009'),
('20261007160008'),
('20261007160007'),
('20261007160006'),
('20261007160005'),
('20261007160004'),
('20261007160003'),
('20261007160002'),
('20261007160001');

