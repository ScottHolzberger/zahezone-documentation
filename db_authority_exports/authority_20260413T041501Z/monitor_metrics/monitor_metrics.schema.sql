--
-- PostgreSQL database dump
--

\restrict blUf1jn7ced1Lsl2ueg35P10gjoFLy4760J0ByKy3gvo74cuNF0ckPfbgsVsGDt

-- Dumped from database version 16.13 (Debian 16.13-1.pgdg13+1)
-- Dumped by pg_dump version 16.13 (Debian 16.13-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: admin; Type: SCHEMA; Schema: -; Owner: metrics_writer
--

CREATE SCHEMA admin;


ALTER SCHEMA admin OWNER TO metrics_writer;

--
-- Name: manage_cfg; Type: SCHEMA; Schema: -; Owner: metrics_writer
--

CREATE SCHEMA manage_cfg;


ALTER SCHEMA manage_cfg OWNER TO metrics_writer;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: sync_customers_to_monitor_cache(); Type: FUNCTION; Schema: manage_cfg; Owner: metrics_writer
--

CREATE FUNCTION manage_cfg.sync_customers_to_monitor_cache() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO public.customers (
    customer_slug,
    display_name,
    status,
    created_ts,
    updated_ts
  )
  SELECT
    c.customer_slug,
    c.display_name,
    c.status,
    NOW(),
    NOW()
  FROM manage_cfg.customers c
  ON CONFLICT (customer_slug) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        status = EXCLUDED.status,
        updated_ts = NOW();
END;
$$;


ALTER FUNCTION manage_cfg.sync_customers_to_monitor_cache() OWNER TO metrics_writer;

--
-- Name: sync_pbx_to_monitor_cache(); Type: FUNCTION; Schema: manage_cfg; Owner: metrics_writer
--

CREATE FUNCTION manage_cfg.sync_pbx_to_monitor_cache() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  r RECORD;
  existing_id INTEGER;
  new_id INTEGER;
BEGIN
  -- Ensure customers exist first (FK safety)
  PERFORM manage_cfg.sync_customers_to_monitor_cache();

  FOR r IN
    SELECT *
    FROM public.v_manage_cfg_pbx
    WHERE pbx_fqdn IS NOT NULL AND pbx_fqdn <> ''
  LOOP
    -- Preserve stable pbx_systems.id (critical for trunks/CDRs)
    SELECT MIN(id)
    INTO existing_id
    FROM public.pbx_systems
    WHERE pbx_fqdn = r.pbx_fqdn;

    -- Enforce CHECK: enabled_requires_secrets_ref
    IF r.credentials_ref IS NULL OR r.credentials_ref = '' THEN
      r.enabled := FALSE;
    END IF;

    IF existing_id IS NULL THEN
      -- Create new PBX safely
      SELECT COALESCE(MAX(id), 0) + 1
      INTO new_id
      FROM public.pbx_systems;

      INSERT INTO public.pbx_systems (
        id,
        display_name,
        customer_slug,
        pbx_fqdn,
        api_base_url,
        enabled,
        secrets_ref,
        poll_interval_seconds,
        updated_at
      )
      VALUES (
        new_id,
        r.customer_name,
        r.customer_slug,
        r.pbx_fqdn,
        r.management_url,
        r.enabled,
        r.credentials_ref,
        r.poll_interval_seconds,
        NOW()
      );
    ELSE
      -- Update existing PBX
      UPDATE public.pbx_systems
      SET
        display_name = r.customer_name,
        customer_slug = r.customer_slug,
        api_base_url = r.management_url,
        enabled = r.enabled,
        secrets_ref = r.credentials_ref,
        poll_interval_seconds = r.poll_interval_seconds,
        updated_at = NOW()
      WHERE id = existing_id;
    END IF;

  END LOOP;
END;
$$;


ALTER FUNCTION manage_cfg.sync_pbx_to_monitor_cache() OWNER TO metrics_writer;

--
-- Name: sync_pbx_to_monitor_cache(text); Type: FUNCTION; Schema: manage_cfg; Owner: metrics_writer
--

CREATE FUNCTION manage_cfg.sync_pbx_to_monitor_cache(actor text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Upsert PBX records into public.pbx_systems (monitor cache)
  INSERT INTO public.pbx_systems (
    id,
    display_name,
    customer_slug,
    pbx_fqdn,
    api_base_url,
    enabled,
    is_multi_tenant,
    secrets_ref,
    updated_at
  )
  SELECT
    -- map stable ID: keep existing monitor pbx_systems.id if you already use numeric IDs there
    -- otherwise switch to a generated mapping table; quickest path is reuse pbx_systems.id via pbx_fqdn lookup:
    COALESCE(ps.id, nextval('pbx_systems_id_seq')),
    v.customer_name,
    v.customer_slug,
    v.pbx_fqdn,
    v.management_url,
    v.enabled,
    COALESCE(ps.is_multi_tenant, false),
    v.credentials_ref,
    NOW()
  FROM public.v_manage_cfg_pbx v
  LEFT JOIN public.pbx_systems ps ON ps.pbx_fqdn = v.pbx_fqdn
  ON CONFLICT (id) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        customer_slug = EXCLUDED.customer_slug,
        pbx_fqdn = EXCLUDED.pbx_fqdn,
        api_base_url = EXCLUDED.api_base_url,
        enabled = EXCLUDED.enabled,
        secrets_ref = EXCLUDED.secrets_ref,
        updated_at = NOW();

END;
$$;


ALTER FUNCTION manage_cfg.sync_pbx_to_monitor_cache(actor text) OWNER TO metrics_writer;

--
-- Name: sync_trunks_to_monitor_cache(text); Type: FUNCTION; Schema: manage_cfg; Owner: metrics_writer
--

CREATE FUNCTION manage_cfg.sync_trunks_to_monitor_cache(actor text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO public.trunks (
    trunk_id,
    customer_slug,
    pbx_id,
    trunk_type,
    status,
    concurrency_cap,
    notes,
    updated_ts
  )
  SELECT
    v.trunk_id,
    v.customer_slug,
    ps.id,
    COALESCE(v.provider, 'unknown'),
    CASE WHEN v.enabled THEN 'active' ELSE 'disabled' END,
    v.concurrency_cap,
    NULL,
    NOW()
  FROM public.v_manage_cfg_trunk v
  LEFT JOIN public.pbx_systems ps ON ps.pbx_fqdn = (
    SELECT pbx_fqdn FROM manage_cfg.pbx_modules WHERE module_id = v.pbx_module_id
  )
  ON CONFLICT (trunk_id) DO UPDATE
    SET customer_slug = EXCLUDED.customer_slug,
        pbx_id = EXCLUDED.pbx_id,
        trunk_type = EXCLUDED.trunk_type,
        status = EXCLUDED.status,
        concurrency_cap = EXCLUDED.concurrency_cap,
        updated_ts = NOW();

END;
$$;


ALTER FUNCTION manage_cfg.sync_trunks_to_monitor_cache(actor text) OWNER TO metrics_writer;

--
-- Name: fn_block_metric_points_mutation(); Type: FUNCTION; Schema: public; Owner: metrics_writer
--

CREATE FUNCTION public.fn_block_metric_points_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'metric_points is append-only (mutation blocked)';
END;
$$;


ALTER FUNCTION public.fn_block_metric_points_mutation() OWNER TO metrics_writer;

--
-- Name: fn_compute_uptime_for_month(date, date, integer); Type: FUNCTION; Schema: public; Owner: metrics_writer
--

CREATE FUNCTION public.fn_compute_uptime_for_month(p_month_start date, p_month_end date, p_heartbeat_ttl_seconds integer DEFAULT 300) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  WITH bounds AS (
    SELECT (p_month_start::timestamptz) AS t0, (p_month_end::timestamptz) AS t1
  ),
  ev AS (
    SELECT e.pbx_id, e.ts, e.status,
           LEAD(e.ts) OVER (PARTITION BY e.pbx_id ORDER BY e.ts) AS next_ts
    FROM public.pbx_status_events e, bounds b
    WHERE e.ts >= b.t0 - interval '1 day'
      AND e.ts <  b.t1 + interval '1 day'
  ),
  intervals AS (
    SELECT
      pbx_id,
      GREATEST(ts, (SELECT t0 FROM bounds)) AS start_ts,
      LEAST(COALESCE(next_ts, (SELECT t1 FROM bounds)), (SELECT t1 FROM bounds)) AS raw_end_ts,
      status
    FROM ev
    WHERE COALESCE(next_ts, (SELECT t1 FROM bounds)) > (SELECT t0 FROM bounds)
  ),
  capped AS (
    SELECT
      pbx_id,
      start_ts,
      CASE
        WHEN raw_end_ts - start_ts > make_interval(secs => p_heartbeat_ttl_seconds)
          THEN start_ts + make_interval(secs => p_heartbeat_ttl_seconds)
        ELSE raw_end_ts
      END AS end_ts,
      CASE
        WHEN raw_end_ts - start_ts > make_interval(secs => p_heartbeat_ttl_seconds)
          THEN (raw_end_ts - (start_ts + make_interval(secs => p_heartbeat_ttl_seconds)))
        ELSE interval '0'
      END AS unknown_part,
      status
    FROM intervals
    WHERE raw_end_ts > start_ts
  ),
  agg AS (
    SELECT
      pbx_id,
      SUM(EXTRACT(EPOCH FROM (end_ts - start_ts)))::bigint AS observed_seconds,
      SUM(CASE WHEN status='up'   THEN EXTRACT(EPOCH FROM (end_ts - start_ts)) ELSE 0 END)::bigint AS up_seconds_raw,
      SUM(CASE WHEN status='down' THEN EXTRACT(EPOCH FROM (end_ts - start_ts)) ELSE 0 END)::bigint AS down_seconds_raw,
      SUM(EXTRACT(EPOCH FROM unknown_part))::bigint AS unknown_seconds
    FROM capped
    GROUP BY pbx_id
  ),
  down_intervals AS (
    SELECT pbx_id, start_ts, end_ts FROM capped WHERE status='down'
  ),
  maint AS (
    SELECT
      m.pbx_id,
      GREATEST(m.start_ts, (SELECT t0 FROM bounds)) AS start_ts,
      LEAST(m.end_ts, (SELECT t1 FROM bounds)) AS end_ts
    FROM public.pbx_maintenance_windows m, bounds
    WHERE m.end_ts > (SELECT t0 FROM bounds)
      AND m.start_ts < (SELECT t1 FROM bounds)
  ),
  overlap AS (
    SELECT
      d.pbx_id,
      SUM(EXTRACT(EPOCH FROM (LEAST(d.end_ts, m.end_ts) - GREATEST(d.start_ts, m.start_ts))))::bigint AS maint_overlap_seconds
    FROM down_intervals d
    JOIN maint m
      ON m.pbx_id = d.pbx_id
     AND m.end_ts > d.start_ts
     AND m.start_ts < d.end_ts
    GROUP BY d.pbx_id
  )
  INSERT INTO public.pbx_uptime_monthly (
    pbx_id, month_start, observed_seconds, up_seconds_raw, down_seconds_raw, unknown_seconds,
    maint_overlap_seconds, down_seconds_sla, uptime_pct_raw, uptime_pct_sla, computed_at
  )
  SELECT
    a.pbx_id,
    p_month_start,
    GREATEST(a.observed_seconds,0),
    GREATEST(a.up_seconds_raw,0),
    GREATEST(a.down_seconds_raw,0),
    GREATEST(a.unknown_seconds,0),
    GREATEST(COALESCE(o.maint_overlap_seconds,0),0),
    GREATEST(a.down_seconds_raw - COALESCE(o.maint_overlap_seconds,0), 0),
    CASE WHEN a.observed_seconds > 0
      THEN ROUND((a.up_seconds_raw::numeric / a.observed_seconds::numeric) * 100.0, 4)
      ELSE 100.0
    END AS uptime_pct_raw,
    CASE WHEN a.observed_seconds > 0
      THEN ROUND(((a.up_seconds_raw + COALESCE(o.maint_overlap_seconds,0))::numeric / a.observed_seconds::numeric) * 100.0, 4)
      ELSE 100.0
    END AS uptime_pct_sla,
    NOW()
  FROM agg a
  LEFT JOIN overlap o ON o.pbx_id=a.pbx_id
  ON CONFLICT (pbx_id, month_start) DO UPDATE
    SET observed_seconds=EXCLUDED.observed_seconds,
        up_seconds_raw=EXCLUDED.up_seconds_raw,
        down_seconds_raw=EXCLUDED.down_seconds_raw,
        unknown_seconds=EXCLUDED.unknown_seconds,
        maint_overlap_seconds=EXCLUDED.maint_overlap_seconds,
        down_seconds_sla=EXCLUDED.down_seconds_sla,
        uptime_pct_raw=EXCLUDED.uptime_pct_raw,
        uptime_pct_sla=EXCLUDED.uptime_pct_sla,
        computed_at=NOW();
END;
$$;


ALTER FUNCTION public.fn_compute_uptime_for_month(p_month_start date, p_month_end date, p_heartbeat_ttl_seconds integer) OWNER TO metrics_writer;

--
-- Name: fn_end_maintenance(bigint); Type: FUNCTION; Schema: public; Owner: metrics_writer
--

CREATE FUNCTION public.fn_end_maintenance(p_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE public.pbx_maintenance_windows
  SET end_ts = NOW()
  WHERE id = p_id AND end_ts > NOW();
END;
$$;


ALTER FUNCTION public.fn_end_maintenance(p_id bigint) OWNER TO metrics_writer;

--
-- Name: fn_record_pbx_status(bigint, text, timestamp with time zone, jsonb, boolean, integer); Type: FUNCTION; Schema: public; Owner: metrics_writer
--

CREATE FUNCTION public.fn_record_pbx_status(p_pbx_id bigint, p_status text, p_ts timestamp with time zone, p_error jsonb DEFAULT NULL::jsonb, p_heartbeat boolean DEFAULT false, p_heartbeat_every_seconds integer DEFAULT 600) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_prev_status text;
  v_last_seen timestamptz;
  v_is_heartbeat boolean := false;
BEGIN
  SELECT status, last_seen_ts INTO v_prev_status, v_last_seen
  FROM public.pbx_status_latest
  WHERE pbx_id = p_pbx_id;

  IF NOT FOUND THEN
    INSERT INTO public.pbx_status_latest (pbx_id, status, last_seen_ts, last_change_ts, last_error)
    VALUES (p_pbx_id, p_status, p_ts, p_ts, p_error);

    INSERT INTO public.pbx_status_events (pbx_id, ts, status, is_heartbeat, error)
    VALUES (p_pbx_id, p_ts, p_status, false, p_error);
    RETURN;
  END IF;

  UPDATE public.pbx_status_latest
  SET last_seen_ts = p_ts,
      last_error = p_error
  WHERE pbx_id = p_pbx_id;

  IF v_prev_status IS DISTINCT FROM p_status THEN
    UPDATE public.pbx_status_latest
    SET status = p_status,
        last_change_ts = p_ts
    WHERE pbx_id = p_pbx_id;

    INSERT INTO public.pbx_status_events (pbx_id, ts, status, is_heartbeat, error)
    VALUES (p_pbx_id, p_ts, p_status, false, p_error);
    RETURN;
  END IF;

  IF p_heartbeat THEN
    v_is_heartbeat := true;
  ELSE
    IF v_last_seen IS NULL OR (p_ts - v_last_seen) >= make_interval(secs => p_heartbeat_every_seconds) THEN
      v_is_heartbeat := true;
    END IF;
  END IF;

  IF v_is_heartbeat THEN
    INSERT INTO public.pbx_status_events (pbx_id, ts, status, is_heartbeat, error)
    VALUES (p_pbx_id, p_ts, p_status, true, p_error);
  END IF;
END;
$$;


ALTER FUNCTION public.fn_record_pbx_status(p_pbx_id bigint, p_status text, p_ts timestamp with time zone, p_error jsonb, p_heartbeat boolean, p_heartbeat_every_seconds integer) OWNER TO metrics_writer;

--
-- Name: fn_start_maintenance(bigint, integer, text, text); Type: FUNCTION; Schema: public; Owner: metrics_writer
--

CREATE FUNCTION public.fn_start_maintenance(p_pbx_id bigint, p_minutes integer, p_reason text DEFAULT NULL::text, p_created_by text DEFAULT NULL::text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.pbx_maintenance_windows (pbx_id, start_ts, end_ts, reason, created_by)
  VALUES (p_pbx_id, NOW(), NOW() + make_interval(mins => p_minutes), p_reason, p_created_by)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;


ALTER FUNCTION public.fn_start_maintenance(p_pbx_id bigint, p_minutes integer, p_reason text, p_created_by text) OWNER TO metrics_writer;

--
-- Name: start_pbx_maintenance(bigint, integer, text, text); Type: FUNCTION; Schema: public; Owner: metrics_writer
--

CREATE FUNCTION public.start_pbx_maintenance(p_pbx_id bigint, p_hours integer DEFAULT 4, p_reason text DEFAULT 'Manual maintenance'::text, p_user text DEFAULT 'admin'::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO pbx_maintenance_windows (
        pbx_id, start_ts, end_ts, reason, created_by
    )
    VALUES (
        p_pbx_id,
        NOW(),
        NOW() + (p_hours || ' hours')::interval,
        p_reason,
        p_user
    );
EXCEPTION
    WHEN exclusion_violation THEN
        RAISE EXCEPTION
          'PBX % already has an overlapping maintenance window', p_pbx_id
          USING ERRCODE = 'check_violation';
END;
$$;


ALTER FUNCTION public.start_pbx_maintenance(p_pbx_id bigint, p_hours integer, p_reason text, p_user text) OWNER TO metrics_writer;

--
-- Name: start_pbx_maintenance(bigint, text, integer, text); Type: FUNCTION; Schema: public; Owner: metrics_writer
--

CREATE FUNCTION public.start_pbx_maintenance(p_pbx_id bigint, p_reason text, p_hours integer DEFAULT 4, p_user text DEFAULT 'admin'::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO pbx_maintenance_windows (
        pbx_id,
        start_ts,
        end_ts,
        reason,
        created_by
    )
    VALUES (
        p_pbx_id,
        NOW(),
        NOW() + (p_hours || ' hours')::interval,
        p_reason,
        p_user
    );
END;
$$;


ALTER FUNCTION public.start_pbx_maintenance(p_pbx_id bigint, p_reason text, p_hours integer, p_user text) OWNER TO metrics_writer;

--
-- Name: stop_pbx_maintenance(bigint); Type: FUNCTION; Schema: public; Owner: metrics_writer
--

CREATE FUNCTION public.stop_pbx_maintenance(p_pbx_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE pbx_maintenance_windows
    SET end_ts = NOW() - INTERVAL '1 second'
    WHERE pbx_id = p_pbx_id
      AND start_ts <= NOW()
      AND end_ts   >= NOW();

    -- Optional: if nothing updated, raise a clean message
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No active maintenance window found for PBX %', p_pbx_id
            USING ERRCODE = 'no_data_found';
    END IF;
END;
$$;


ALTER FUNCTION public.stop_pbx_maintenance(p_pbx_id bigint) OWNER TO metrics_writer;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: customers; Type: TABLE; Schema: manage_cfg; Owner: metrics_writer
--

CREATE TABLE manage_cfg.customers (
    halo_customer_id bigint NOT NULL,
    customer_slug text NOT NULL,
    display_name text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    billing_ref text,
    notes text,
    created_by text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    halo_billing_id bigint
);


ALTER TABLE manage_cfg.customers OWNER TO metrics_writer;

--
-- Name: modules; Type: TABLE; Schema: manage_cfg; Owner: metrics_writer
--

CREATE TABLE manage_cfg.modules (
    module_id uuid DEFAULT gen_random_uuid() NOT NULL,
    halo_customer_id bigint NOT NULL,
    module_type text NOT NULL,
    external_key text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    config_version bigint DEFAULT 1 NOT NULL,
    created_by text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE manage_cfg.modules OWNER TO metrics_writer;

--
-- Name: v_customers; Type: VIEW; Schema: admin; Owner: metrics_writer
--

CREATE VIEW admin.v_customers AS
 SELECT c.halo_customer_id,
    c.display_name,
    count(DISTINCT m_pbx.module_id) AS pbx_count,
    count(DISTINCT m_trk.module_id) AS trunk_count
   FROM ((manage_cfg.customers c
     LEFT JOIN manage_cfg.modules m_pbx ON (((m_pbx.halo_customer_id = c.halo_customer_id) AND (m_pbx.module_type = 'PBX'::text) AND (m_pbx.enabled = true))))
     LEFT JOIN manage_cfg.modules m_trk ON (((m_trk.halo_customer_id = c.halo_customer_id) AND (m_trk.module_type = 'TRUNK'::text) AND (m_trk.enabled = true))))
  WHERE ((c.status = 'active'::text) AND (c.halo_billing_id IS NOT NULL))
  GROUP BY c.halo_customer_id, c.display_name
  ORDER BY c.display_name;


ALTER VIEW admin.v_customers OWNER TO metrics_writer;

--
-- Name: v_customers_all; Type: VIEW; Schema: admin; Owner: metrics_writer
--

CREATE VIEW admin.v_customers_all AS
 SELECT c.halo_customer_id,
    c.halo_billing_id,
    c.customer_slug,
    c.display_name,
    c.status,
    count(DISTINCT m.module_id) AS total_services,
        CASE
            WHEN (c.halo_customer_id < 0) THEN 'ARCHIVED'::text
            ELSE 'ACTIVE'::text
        END AS lifecycle_state
   FROM (manage_cfg.customers c
     LEFT JOIN manage_cfg.modules m ON ((m.halo_customer_id = c.halo_customer_id)))
  GROUP BY c.halo_customer_id, c.halo_billing_id, c.customer_slug, c.display_name, c.status
  ORDER BY
        CASE
            WHEN (c.halo_customer_id < 0) THEN 'ARCHIVED'::text
            ELSE 'ACTIVE'::text
        END, c.display_name;


ALTER VIEW admin.v_customers_all OWNER TO metrics_writer;

--
-- Name: v_pbx; Type: VIEW; Schema: admin; Owner: metrics_writer
--

CREATE VIEW admin.v_pbx AS
 SELECT m.module_id,
    c.display_name AS customer_name,
    m.external_key AS pbx_fqdn,
    m.enabled
   FROM (manage_cfg.modules m
     JOIN manage_cfg.customers c ON ((c.halo_customer_id = m.halo_customer_id)))
  WHERE ((m.module_type = 'PBX'::text) AND (m.enabled = true))
  ORDER BY c.display_name, m.external_key;


ALTER VIEW admin.v_pbx OWNER TO metrics_writer;

--
-- Name: trunk_modules; Type: TABLE; Schema: manage_cfg; Owner: metrics_writer
--

CREATE TABLE manage_cfg.trunk_modules (
    module_id uuid NOT NULL,
    trunk_id text NOT NULL,
    provider text,
    credentials_ref text,
    pbx_module_id uuid,
    monitoring_enabled boolean DEFAULT true NOT NULL,
    concurrency_cap integer,
    notes text
);


ALTER TABLE manage_cfg.trunk_modules OWNER TO metrics_writer;

--
-- Name: v_trunks; Type: VIEW; Schema: admin; Owner: metrics_writer
--

CREATE VIEW admin.v_trunks AS
 SELECT m.module_id,
    c.display_name AS customer_name,
    m.external_key AS trunk_id,
    tm.provider,
    tm.concurrency_cap,
    tm.monitoring_enabled,
    m.enabled
   FROM ((manage_cfg.modules m
     JOIN manage_cfg.trunk_modules tm ON ((tm.module_id = m.module_id)))
     JOIN manage_cfg.customers c ON ((c.halo_customer_id = m.halo_customer_id)))
  WHERE ((m.module_type = 'TRUNK'::text) AND (m.enabled = true))
  ORDER BY c.display_name, m.external_key;


ALTER VIEW admin.v_trunks OWNER TO metrics_writer;

--
-- Name: customer_halo_map; Type: TABLE; Schema: manage_cfg; Owner: metrics_writer
--

CREATE TABLE manage_cfg.customer_halo_map (
    customer_slug text NOT NULL,
    halo_customer_id bigint,
    customer_name text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE manage_cfg.customer_halo_map OWNER TO metrics_writer;

--
-- Name: pbx_customer_map; Type: TABLE; Schema: manage_cfg; Owner: metrics_writer
--

CREATE TABLE manage_cfg.pbx_customer_map (
    pbx_fqdn text NOT NULL,
    customer_slug text NOT NULL,
    updated_by text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE manage_cfg.pbx_customer_map OWNER TO metrics_writer;

--
-- Name: pbx_modules; Type: TABLE; Schema: manage_cfg; Owner: metrics_writer
--

CREATE TABLE manage_cfg.pbx_modules (
    module_id uuid NOT NULL,
    pbx_fqdn text NOT NULL,
    management_url text,
    auth_method text DEFAULT 'basic'::text NOT NULL,
    credentials_ref text,
    verify_tls boolean DEFAULT true NOT NULL,
    polling_enabled boolean DEFAULT true NOT NULL,
    poll_interval_seconds integer,
    notes text
);


ALTER TABLE manage_cfg.pbx_modules OWNER TO metrics_writer;

--
-- Name: trunk_import_stage; Type: TABLE; Schema: manage_cfg; Owner: metrics_writer
--

CREATE TABLE manage_cfg.trunk_import_stage (
    trunk_id text NOT NULL,
    concurrency_cap integer,
    halo_billing_id bigint
);


ALTER TABLE manage_cfg.trunk_import_stage OWNER TO metrics_writer;

--
-- Name: trunks_import_stage; Type: TABLE; Schema: manage_cfg; Owner: metrics_writer
--

CREATE TABLE manage_cfg.trunks_import_stage (
    trunk_id text NOT NULL,
    company_name text,
    concurrency_cap integer,
    halo_id bigint
);


ALTER TABLE manage_cfg.trunks_import_stage OWNER TO metrics_writer;

--
-- Name: active_calls_10m; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.active_calls_10m (
    pbx_id bigint NOT NULL,
    bucket_ts timestamp with time zone NOT NULL,
    samples integer NOT NULL,
    value_max double precision
);


ALTER TABLE public.active_calls_10m OWNER TO metrics_writer;

--
-- Name: active_calls_1d; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.active_calls_1d (
    pbx_id bigint NOT NULL,
    bucket_ts timestamp with time zone NOT NULL,
    samples integer NOT NULL,
    value_max double precision
);


ALTER TABLE public.active_calls_1d OWNER TO metrics_writer;

--
-- Name: active_calls_1h; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.active_calls_1h (
    pbx_id bigint NOT NULL,
    bucket_ts timestamp with time zone NOT NULL,
    samples integer NOT NULL,
    value_max double precision
);


ALTER TABLE public.active_calls_1h OWNER TO metrics_writer;

--
-- Name: active_calls_1m; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.active_calls_1m (
    pbx_id bigint NOT NULL,
    bucket_ts timestamp with time zone NOT NULL,
    samples integer NOT NULL,
    value_max double precision
);


ALTER TABLE public.active_calls_1m OWNER TO metrics_writer;

--
-- Name: active_calls_5m; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.active_calls_5m (
    pbx_id bigint NOT NULL,
    bucket_ts timestamp with time zone NOT NULL,
    samples integer NOT NULL,
    value_max double precision
);


ALTER TABLE public.active_calls_5m OWNER TO metrics_writer;

--
-- Name: alert_events; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.alert_events (
    id bigint NOT NULL,
    customer_slug text NOT NULL,
    pbx_id bigint NOT NULL,
    event_type text NOT NULL,
    severity text DEFAULT 'warning'::text NOT NULL,
    triggered_at timestamp with time zone DEFAULT now() NOT NULL,
    payload jsonb
);


ALTER TABLE public.alert_events OWNER TO metrics_writer;

--
-- Name: alert_events_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.alert_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.alert_events_id_seq OWNER TO metrics_writer;

--
-- Name: alert_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.alert_events_id_seq OWNED BY public.alert_events.id;


--
-- Name: alert_state; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.alert_state (
    pbx_id bigint NOT NULL,
    state_key text NOT NULL,
    state_value text NOT NULL,
    last_sent_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.alert_state OWNER TO metrics_writer;

--
-- Name: audit_number_allocation_rates_after_20260406; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.audit_number_allocation_rates_after_20260406 (
    id bigint,
    carrier_name text,
    number_type text,
    monthly_cost numeric(10,5),
    currency text,
    effective_from date,
    effective_to date,
    notes text,
    created_at timestamp with time zone
);


ALTER TABLE public.audit_number_allocation_rates_after_20260406 OWNER TO metrics_writer;

--
-- Name: audit_number_allocation_rates_before_20260406; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.audit_number_allocation_rates_before_20260406 (
    id bigint,
    carrier_name text,
    number_type text,
    monthly_cost numeric(10,5),
    currency text,
    effective_from date,
    effective_to date,
    notes text,
    created_at timestamp with time zone
);


ALTER TABLE public.audit_number_allocation_rates_before_20260406 OWNER TO metrics_writer;

--
-- Name: billing_customer_plan; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.billing_customer_plan (
    customer_slug text NOT NULL,
    plan_code text NOT NULL,
    include_inbound_minutes boolean DEFAULT true NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT billing_customer_plan_check CHECK (((effective_to IS NULL) OR (effective_to > effective_from)))
);


ALTER TABLE public.billing_customer_plan OWNER TO metrics_writer;

--
-- Name: billing_plan_catalog; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.billing_plan_catalog (
    plan_code text NOT NULL,
    included_minutes integer NOT NULL,
    monthly_fee_ex_gst numeric(12,2) DEFAULT 0 NOT NULL,
    overage_rate_per_minute numeric(10,4) DEFAULT 0.10 NOT NULL,
    outbound_1300_rate_per_call numeric(10,4) DEFAULT 0.30 NOT NULL,
    currency text DEFAULT 'AUD'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT billing_plan_catalog_included_minutes_check CHECK ((included_minutes >= 0))
);


ALTER TABLE public.billing_plan_catalog OWNER TO metrics_writer;

--
-- Name: call_cost_rates; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.call_cost_rates (
    id bigint NOT NULL,
    carrier_name text NOT NULL,
    trunk_name text NOT NULL,
    call_type text NOT NULL,
    billing_unit text NOT NULL,
    rate_value numeric(12,6) NOT NULL,
    currency text DEFAULT 'AUD'::text NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT call_cost_rates_billing_unit_check CHECK ((billing_unit = ANY (ARRAY['per_minute'::text, 'per_call'::text]))),
    CONSTRAINT call_cost_rates_check CHECK (((effective_to IS NULL) OR (effective_to > effective_from)))
);


ALTER TABLE public.call_cost_rates OWNER TO metrics_writer;

--
-- Name: call_cost_rates_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.call_cost_rates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.call_cost_rates_id_seq OWNER TO metrics_writer;

--
-- Name: call_cost_rates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.call_cost_rates_id_seq OWNED BY public.call_cost_rates.id;


--
-- Name: call_volume_records; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.call_volume_records (
    id bigint NOT NULL,
    customer_slug text DEFAULT 'unmapped'::text NOT NULL,
    customer_name text DEFAULT 'Unmapped'::text NOT NULL,
    account_id text NOT NULL,
    direction text NOT NULL,
    call_type text NOT NULL,
    connect_ts timestamp with time zone NOT NULL,
    disconnect_ts timestamp with time zone NOT NULL,
    call_date date NOT NULL,
    call_length_sec integer NOT NULL,
    source_file text DEFAULT ''::text NOT NULL,
    source_row integer DEFAULT 0 NOT NULL,
    record_hash text NOT NULL
);


ALTER TABLE public.call_volume_records OWNER TO metrics_writer;

--
-- Name: call_volume_records_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.call_volume_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.call_volume_records_id_seq OWNER TO metrics_writer;

--
-- Name: call_volume_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.call_volume_records_id_seq OWNED BY public.call_volume_records.id;


--
-- Name: call_volume_records_stage; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE UNLOGGED TABLE public.call_volume_records_stage (
    customer_slug text,
    customer_name text,
    account_id text,
    direction text,
    call_type text,
    connect_ts timestamp with time zone,
    disconnect_ts timestamp with time zone,
    call_date date,
    call_length_sec integer,
    source_file text,
    source_row integer,
    record_hash text
);


ALTER TABLE public.call_volume_records_stage OWNER TO metrics_writer;

--
-- Name: collector_3cx_session_probe; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.collector_3cx_session_probe (
    id bigint NOT NULL,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    pbx_name text,
    login_ok boolean,
    api_status integer,
    response_ms integer,
    error text
);


ALTER TABLE public.collector_3cx_session_probe OWNER TO metrics_writer;

--
-- Name: collector_3cx_session_probe_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.collector_3cx_session_probe_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.collector_3cx_session_probe_id_seq OWNER TO metrics_writer;

--
-- Name: collector_3cx_session_probe_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.collector_3cx_session_probe_id_seq OWNED BY public.collector_3cx_session_probe.id;


--
-- Name: collector_api_probe; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.collector_api_probe (
    id bigint NOT NULL,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    pbx_name text NOT NULL,
    url text NOT NULL,
    http_status integer,
    response_ms integer,
    error text
);


ALTER TABLE public.collector_api_probe OWNER TO metrics_writer;

--
-- Name: collector_api_probe_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.collector_api_probe_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.collector_api_probe_id_seq OWNER TO metrics_writer;

--
-- Name: collector_api_probe_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.collector_api_probe_id_seq OWNED BY public.collector_api_probe.id;


--
-- Name: collector_heartbeat; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.collector_heartbeat (
    id bigint NOT NULL,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    pbx_name text NOT NULL,
    message text NOT NULL
);


ALTER TABLE public.collector_heartbeat OWNER TO metrics_writer;

--
-- Name: collector_heartbeat_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.collector_heartbeat_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.collector_heartbeat_id_seq OWNER TO metrics_writer;

--
-- Name: collector_heartbeat_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.collector_heartbeat_id_seq OWNED BY public.collector_heartbeat.id;


--
-- Name: costing_trunk_exclusions; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.costing_trunk_exclusions (
    trunk_name text NOT NULL,
    exclude_from date NOT NULL,
    exclude_to date,
    reason text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.costing_trunk_exclusions OWNER TO metrics_writer;

--
-- Name: customers; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.customers (
    customer_slug text NOT NULL,
    display_name text NOT NULL,
    billing_ref text,
    status text DEFAULT 'active'::text NOT NULL,
    created_ts timestamp with time zone DEFAULT now() NOT NULL,
    updated_ts timestamp with time zone DEFAULT now() NOT NULL,
    notes text
);


ALTER TABLE public.customers OWNER TO metrics_writer;

--
-- Name: manage_audit_log; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.manage_audit_log (
    audit_id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_email text NOT NULL,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id text,
    details jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.manage_audit_log OWNER TO metrics_writer;

--
-- Name: manage_customers; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.manage_customers (
    customer_slug text NOT NULL,
    notes text,
    created_by text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.manage_customers OWNER TO metrics_writer;

--
-- Name: manage_pbxs; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.manage_pbxs (
    pbx_id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_slug text NOT NULL,
    pbx_system_id uuid,
    name text NOT NULL,
    type text DEFAULT '3CX'::text NOT NULL,
    management_url text NOT NULL,
    auth_method text NOT NULL,
    collector_id text,
    maintenance_mode boolean DEFAULT false NOT NULL,
    status text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT manage_pbxs_status_check CHECK ((status = ANY (ARRAY['ONLINE'::text, 'DEGRADED'::text, 'OFFLINE'::text, 'MAINTENANCE'::text])))
);


ALTER TABLE public.manage_pbxs OWNER TO metrics_writer;

--
-- Name: manage_trunks; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.manage_trunks (
    trunk_id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_slug text NOT NULL,
    trunk_fk uuid,
    provider text NOT NULL,
    concurrency_limit integer,
    obsolete_flag boolean DEFAULT false NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.manage_trunks OWNER TO metrics_writer;

--
-- Name: manage_users; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.manage_users (
    user_id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    role text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT manage_users_role_check CHECK ((role = ANY (ARRAY['SUPER_ADMIN'::text, 'OPS_ADMIN'::text, 'READ_ONLY'::text])))
);


ALTER TABLE public.manage_users OWNER TO metrics_writer;

--
-- Name: metric_points; Type: TABLE; Schema: public; Owner: metrics_owner
--

CREATE TABLE public.metric_points (
    pbx_id bigint NOT NULL,
    metric_name text NOT NULL,
    ts timestamp with time zone NOT NULL,
    value_num numeric,
    value_json jsonb
);


ALTER TABLE public.metric_points OWNER TO metrics_owner;

--
-- Name: number_allocation_rates; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.number_allocation_rates (
    id bigint NOT NULL,
    carrier_name text NOT NULL,
    number_type text NOT NULL,
    monthly_cost numeric(10,5) NOT NULL,
    currency text DEFAULT 'AUD'::text NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT number_allocation_rates_check CHECK (((effective_to IS NULL) OR (effective_to > effective_from)))
);


ALTER TABLE public.number_allocation_rates OWNER TO metrics_writer;

--
-- Name: number_allocation_rates_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.number_allocation_rates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.number_allocation_rates_id_seq OWNER TO metrics_writer;

--
-- Name: number_allocation_rates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.number_allocation_rates_id_seq OWNED BY public.number_allocation_rates.id;


--
-- Name: number_allocations; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.number_allocations (
    id bigint NOT NULL,
    carrier_name text NOT NULL,
    number_type text NOT NULL,
    quantity integer NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    account_id text,
    CONSTRAINT number_allocations_check CHECK (((effective_to IS NULL) OR (effective_to > effective_from))),
    CONSTRAINT number_allocations_quantity_check CHECK ((quantity >= 0))
);


ALTER TABLE public.number_allocations OWNER TO metrics_writer;

--
-- Name: number_allocations_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.number_allocations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.number_allocations_id_seq OWNER TO metrics_writer;

--
-- Name: number_allocations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.number_allocations_id_seq OWNED BY public.number_allocations.id;


--
-- Name: outbound_call_duration_daily; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.outbound_call_duration_daily (
    call_date date NOT NULL,
    customer_slug text NOT NULL,
    account_id text NOT NULL,
    call_type text NOT NULL,
    total_duration_sec bigint NOT NULL,
    call_count bigint NOT NULL,
    last_updated timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.outbound_call_duration_daily OWNER TO metrics_writer;

--
-- Name: outbound_call_duration_monthly; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.outbound_call_duration_monthly (
    month_start date NOT NULL,
    customer_slug text NOT NULL,
    account_id text NOT NULL,
    call_type text NOT NULL,
    total_duration_sec bigint NOT NULL,
    call_count bigint NOT NULL,
    is_closed boolean DEFAULT false NOT NULL,
    closed_at timestamp with time zone,
    last_updated timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.outbound_call_duration_monthly OWNER TO metrics_writer;

--
-- Name: outbound_total_cost_monthly; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.outbound_total_cost_monthly (
    month_start date NOT NULL,
    account_id text NOT NULL,
    usage_cost_aud numeric(14,4) DEFAULT 0 NOT NULL,
    concurrency_cost_aud numeric(14,4) DEFAULT 0 NOT NULL,
    number_rental_cost_aud numeric(14,4) DEFAULT 0 NOT NULL,
    total_cost_aud numeric(14,4) DEFAULT 0 NOT NULL,
    last_updated timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.outbound_total_cost_monthly OWNER TO metrics_writer;

--
-- Name: pbx_audit_log; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.pbx_audit_log (
    id bigint NOT NULL,
    pbx_id integer NOT NULL,
    actor text NOT NULL,
    action text NOT NULL,
    details jsonb,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.pbx_audit_log OWNER TO metrics_writer;

--
-- Name: pbx_audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.pbx_audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pbx_audit_log_id_seq OWNER TO metrics_writer;

--
-- Name: pbx_audit_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.pbx_audit_log_id_seq OWNED BY public.pbx_audit_log.id;


--
-- Name: pbx_instances; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.pbx_instances (
    id bigint NOT NULL,
    customer_slug text NOT NULL,
    name text NOT NULL,
    base_url text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.pbx_instances OWNER TO metrics_writer;

--
-- Name: pbx_instances_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.pbx_instances_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pbx_instances_id_seq OWNER TO metrics_writer;

--
-- Name: pbx_instances_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.pbx_instances_id_seq OWNED BY public.pbx_instances.id;


--
-- Name: pbx_maintenance_windows; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.pbx_maintenance_windows (
    id bigint NOT NULL,
    pbx_id bigint NOT NULL,
    start_ts timestamp with time zone NOT NULL,
    end_ts timestamp with time zone NOT NULL,
    reason text,
    created_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pbx_maintenance_windows_check CHECK ((end_ts > start_ts))
);


ALTER TABLE public.pbx_maintenance_windows OWNER TO metrics_writer;

--
-- Name: pbx_maintenance_windows_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.pbx_maintenance_windows_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pbx_maintenance_windows_id_seq OWNER TO metrics_writer;

--
-- Name: pbx_maintenance_windows_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.pbx_maintenance_windows_id_seq OWNED BY public.pbx_maintenance_windows.id;


--
-- Name: pbx_metric_latest; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.pbx_metric_latest (
    pbx_id bigint NOT NULL,
    metric_name text NOT NULL,
    ts timestamp with time zone NOT NULL,
    value_num double precision,
    value_json jsonb
);


ALTER TABLE public.pbx_metric_latest OWNER TO metrics_writer;

--
-- Name: pbx_systems; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.pbx_systems (
    id integer NOT NULL,
    display_name text DEFAULT ''::text NOT NULL,
    customer_name text,
    environment text,
    enabled boolean DEFAULT true NOT NULL,
    maintenance_mode boolean DEFAULT false NOT NULL,
    maintenance_reason text,
    maintenance_until timestamp with time zone,
    maintenance_window_id bigint,
    pbx_fqdn text,
    api_base_url text,
    timezone text,
    poll_interval_seconds integer,
    secrets_ref text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    is_multi_tenant boolean DEFAULT false NOT NULL,
    customer_slug text,
    CONSTRAINT enabled_requires_secrets_ref CHECK (((enabled = false) OR (secrets_ref IS NOT NULL))),
    CONSTRAINT pbx_systems_fqdn_not_null CHECK (((pbx_fqdn IS NOT NULL) AND (pbx_fqdn <> ''::text)))
);


ALTER TABLE public.pbx_systems OWNER TO metrics_writer;

--
-- Name: pbx_poll_targets; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.pbx_poll_targets AS
 SELECT id,
    display_name,
    customer_name,
    environment,
    enabled,
    maintenance_mode,
    maintenance_reason,
    maintenance_until,
    maintenance_window_id,
    pbx_fqdn,
    api_base_url,
    timezone,
    poll_interval_seconds,
    secrets_ref,
    created_at,
    updated_at
   FROM public.pbx_systems
  WHERE ((enabled = true) AND (maintenance_mode = false));


ALTER VIEW public.pbx_poll_targets OWNER TO metrics_writer;

--
-- Name: pbx_status_events; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.pbx_status_events (
    id bigint NOT NULL,
    pbx_id bigint NOT NULL,
    ts timestamp with time zone NOT NULL,
    status text NOT NULL,
    is_heartbeat boolean DEFAULT false NOT NULL,
    error jsonb,
    CONSTRAINT pbx_status_events_status_check CHECK ((status = ANY (ARRAY['up'::text, 'down'::text])))
);


ALTER TABLE public.pbx_status_events OWNER TO metrics_writer;

--
-- Name: pbx_status_events_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.pbx_status_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pbx_status_events_id_seq OWNER TO metrics_writer;

--
-- Name: pbx_status_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.pbx_status_events_id_seq OWNED BY public.pbx_status_events.id;


--
-- Name: pbx_status_latest; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.pbx_status_latest (
    pbx_id bigint NOT NULL,
    status text NOT NULL,
    last_seen_ts timestamp with time zone NOT NULL,
    last_change_ts timestamp with time zone NOT NULL,
    last_error jsonb,
    CONSTRAINT pbx_status_latest_status_check CHECK ((status = ANY (ARRAY['up'::text, 'down'::text])))
);


ALTER TABLE public.pbx_status_latest OWNER TO metrics_writer;

--
-- Name: pbx_system_flags; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.pbx_system_flags (
    pbx_id integer NOT NULL,
    is_multicompany boolean NOT NULL,
    last_checked_utc timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.pbx_system_flags OWNER TO metrics_writer;

--
-- Name: pbx_uptime_monthly; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.pbx_uptime_monthly (
    pbx_id bigint NOT NULL,
    month_start date NOT NULL,
    observed_seconds bigint NOT NULL,
    up_seconds_raw bigint NOT NULL,
    down_seconds_raw bigint NOT NULL,
    unknown_seconds bigint NOT NULL,
    maint_overlap_seconds bigint NOT NULL,
    down_seconds_sla bigint NOT NULL,
    uptime_pct_raw numeric(7,4) NOT NULL,
    uptime_pct_sla numeric(7,4) NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.pbx_uptime_monthly OWNER TO metrics_writer;

--
-- Name: rollup_state; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.rollup_state (
    name text NOT NULL,
    last_rolled_ts timestamp with time zone DEFAULT '1970-01-01 00:00:00+00'::timestamp with time zone NOT NULL
);


ALTER TABLE public.rollup_state OWNER TO metrics_writer;

--
-- Name: stg_breeze_numbers; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.stg_breeze_numbers (
    account_id text,
    did text
);


ALTER TABLE public.stg_breeze_numbers OWNER TO metrics_writer;

--
-- Name: system_metadata; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.system_metadata (
    key text NOT NULL,
    value text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.system_metadata OWNER TO metrics_writer;

--
-- Name: trunk_concurrency_allocations; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.trunk_concurrency_allocations (
    id bigint NOT NULL,
    carrier_name text NOT NULL,
    trunk_name text NOT NULL,
    concurrent_calls integer NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT trunk_concurrency_allocations_check CHECK (((effective_to IS NULL) OR (effective_to > effective_from))),
    CONSTRAINT trunk_concurrency_allocations_concurrent_calls_check CHECK ((concurrent_calls >= 0))
);


ALTER TABLE public.trunk_concurrency_allocations OWNER TO metrics_writer;

--
-- Name: trunk_concurrency_allocations_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.trunk_concurrency_allocations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.trunk_concurrency_allocations_id_seq OWNER TO metrics_writer;

--
-- Name: trunk_concurrency_allocations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.trunk_concurrency_allocations_id_seq OWNED BY public.trunk_concurrency_allocations.id;


--
-- Name: trunk_concurrency_rates; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.trunk_concurrency_rates (
    id bigint NOT NULL,
    carrier_name text NOT NULL,
    trunk_name text NOT NULL,
    cost_per_channel numeric(10,2) NOT NULL,
    currency text DEFAULT 'AUD'::text NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT trunk_concurrency_rates_check CHECK (((effective_to IS NULL) OR (effective_to > effective_from)))
);


ALTER TABLE public.trunk_concurrency_rates OWNER TO metrics_writer;

--
-- Name: trunk_concurrency_rates_id_seq; Type: SEQUENCE; Schema: public; Owner: metrics_writer
--

CREATE SEQUENCE public.trunk_concurrency_rates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.trunk_concurrency_rates_id_seq OWNER TO metrics_writer;

--
-- Name: trunk_concurrency_rates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: metrics_writer
--

ALTER SEQUENCE public.trunk_concurrency_rates_id_seq OWNED BY public.trunk_concurrency_rates.id;


--
-- Name: trunks; Type: TABLE; Schema: public; Owner: metrics_writer
--

CREATE TABLE public.trunks (
    trunk_id text NOT NULL,
    customer_slug text NOT NULL,
    pbx_id integer NOT NULL,
    trunk_type text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    concurrency_cap integer,
    notes text,
    created_ts timestamp with time zone DEFAULT now() NOT NULL,
    updated_ts timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.trunks OWNER TO metrics_writer;

--
-- Name: v_admin_pbx_overview; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_admin_pbx_overview AS
 WITH last_ts AS (
         SELECT pbx_metric_latest.pbx_id,
            max(pbx_metric_latest.ts) AS last_polled
           FROM public.pbx_metric_latest
          GROUP BY pbx_metric_latest.pbx_id
        ), inst AS (
         SELECT pbx_instances.id AS pbx_id,
            pbx_instances.name AS instance_name,
            pbx_instances.base_url AS instance_base_url
           FROM public.pbx_instances
        ), sys AS (
         SELECT pbx_systems.id AS pbx_id,
            pbx_systems.display_name,
            pbx_systems.enabled,
            pbx_systems.maintenance_mode,
            pbx_systems.maintenance_until,
            pbx_systems.maintenance_reason,
            pbx_systems.api_base_url,
            pbx_systems.is_multi_tenant
           FROM public.pbx_systems
        )
 SELECT sys.pbx_id,
    COALESCE(inst.instance_name, sys.display_name, ('PBX '::text || (sys.pbx_id)::text)) AS display_name,
    COALESCE(inst.instance_base_url, sys.api_base_url, ''::text) AS base_url,
    sys.enabled,
    sys.maintenance_mode,
    sys.maintenance_until,
    sys.maintenance_reason,
    sys.is_multi_tenant,
    last_ts.last_polled,
        CASE
            WHEN sys.maintenance_mode THEN 'MAINT'::text
            WHEN (last_ts.last_polled IS NULL) THEN 'UNKNOWN'::text
            WHEN ((now() - last_ts.last_polled) <= '00:02:00'::interval) THEN 'OK'::text
            WHEN ((now() - last_ts.last_polled) <= '00:10:00'::interval) THEN 'WARN'::text
            ELSE 'STALE'::text
        END AS health_label
   FROM ((sys
     LEFT JOIN inst ON ((inst.pbx_id = sys.pbx_id)))
     LEFT JOIN last_ts ON ((last_ts.pbx_id = sys.pbx_id)));


ALTER VIEW public.v_admin_pbx_overview OWNER TO metrics_writer;

--
-- Name: v_billing_calls_deduped; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_billing_calls_deduped AS
 WITH ranked AS (
         SELECT r.id,
            r.customer_slug,
            r.customer_name,
            r.account_id,
            r.direction,
            r.call_type,
            r.connect_ts,
            r.disconnect_ts,
            r.call_date,
            r.call_length_sec,
            r.source_file,
            r.source_row,
            r.record_hash,
            row_number() OVER (PARTITION BY COALESCE(NULLIF(r.record_hash, ''::text), concat_ws('|'::text, r.account_id, r.direction, r.call_type, (r.connect_ts)::text, (r.disconnect_ts)::text, (r.call_length_sec)::text)) ORDER BY r.id) AS rn
           FROM public.call_volume_records r
        )
 SELECT id,
    customer_slug,
    customer_name,
    account_id,
    direction,
    call_type,
    connect_ts,
    disconnect_ts,
    call_date,
    call_length_sec,
    source_file,
    source_row,
    record_hash,
    rn
   FROM ranked
  WHERE (rn = 1);


ALTER VIEW public.v_billing_calls_deduped OWNER TO metrics_writer;

--
-- Name: v_billing_calls_classified; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_billing_calls_classified AS
 SELECT id,
    customer_slug,
    customer_name,
    account_id,
    direction,
    call_type,
    connect_ts,
    disconnect_ts,
    call_date,
    call_length_sec,
    source_file,
    source_row,
    record_hash,
        CASE
            WHEN ((direction = 'outbound'::text) AND ((call_type ~~* '%13/1300%'::text) OR (call_type ~~* '%13%'::text) OR (call_type ~~* '%1300%'::text))) THEN 'OUTBOUND_1300_CALLS'::text
            WHEN ((direction = 'outbound'::text) AND ((call_type ~~* '%Local/National%'::text) OR (call_type ~~* '%Mobile%'::text))) THEN 'OUTBOUND_DOMESTIC_MINUTES'::text
            WHEN ((direction = 'inbound'::text) AND ((call_type = 'All Inbound'::text) OR (call_type ~~* '%1300/1800 Inbound%'::text))) THEN 'INBOUND_MINUTES'::text
            ELSE 'EXCLUDED'::text
        END AS billing_bucket,
    (direction = 'outbound'::text) AS is_outbound,
    (direction = 'inbound'::text) AS is_inbound
   FROM public.v_billing_calls_deduped d;


ALTER VIEW public.v_billing_calls_classified OWNER TO metrics_writer;

--
-- Name: v_billing_customer_plan_active; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_billing_customer_plan_active AS
 SELECT cp.customer_slug,
    cp.plan_code,
    cp.include_inbound_minutes,
    cp.effective_from,
    cp.effective_to,
    pc.included_minutes,
    pc.monthly_fee_ex_gst,
    pc.overage_rate_per_minute,
    pc.outbound_1300_rate_per_call,
    pc.currency
   FROM (public.billing_customer_plan cp
     JOIN public.billing_plan_catalog pc ON ((pc.plan_code = cp.plan_code)));


ALTER VIEW public.v_billing_customer_plan_active OWNER TO metrics_writer;

--
-- Name: v_billing_monthly_usage; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_billing_monthly_usage AS
 WITH base AS (
         SELECT v_billing_calls_classified.customer_slug,
            (date_trunc('month'::text, v_billing_calls_classified.connect_ts))::date AS billing_month,
            v_billing_calls_classified.billing_bucket,
            v_billing_calls_classified.call_length_sec
           FROM public.v_billing_calls_classified
          WHERE (v_billing_calls_classified.connect_ts IS NOT NULL)
        )
 SELECT customer_slug,
    billing_month,
    sum(
        CASE
            WHEN (billing_bucket = 'OUTBOUND_DOMESTIC_MINUTES'::text) THEN call_length_sec
            ELSE 0
        END) AS outbound_domestic_seconds,
    sum(
        CASE
            WHEN (billing_bucket = 'INBOUND_MINUTES'::text) THEN call_length_sec
            ELSE 0
        END) AS inbound_seconds,
    count(*) FILTER (WHERE (billing_bucket = 'OUTBOUND_1300_CALLS'::text)) AS outbound_1300_calls,
    (sum(
        CASE
            WHEN (billing_bucket = 'OUTBOUND_DOMESTIC_MINUTES'::text) THEN call_length_sec
            ELSE 0
        END) + sum(
        CASE
            WHEN (billing_bucket = 'INBOUND_MINUTES'::text) THEN call_length_sec
            ELSE 0
        END)) AS total_eligible_seconds,
    (ceil((((sum(
        CASE
            WHEN (billing_bucket = 'OUTBOUND_DOMESTIC_MINUTES'::text) THEN call_length_sec
            ELSE 0
        END) + sum(
        CASE
            WHEN (billing_bucket = 'INBOUND_MINUTES'::text) THEN call_length_sec
            ELSE 0
        END)))::numeric / (60)::numeric)))::bigint AS total_minutes_used
   FROM base
  GROUP BY customer_slug, billing_month;


ALTER VIEW public.v_billing_monthly_usage OWNER TO metrics_writer;

--
-- Name: v_billing_monthly_invoice_lines; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_billing_monthly_invoice_lines AS
 WITH u AS (
         SELECT v_billing_monthly_usage.customer_slug,
            v_billing_monthly_usage.billing_month,
            v_billing_monthly_usage.outbound_domestic_seconds,
            v_billing_monthly_usage.inbound_seconds,
            v_billing_monthly_usage.outbound_1300_calls,
            v_billing_monthly_usage.total_eligible_seconds,
            v_billing_monthly_usage.total_minutes_used
           FROM public.v_billing_monthly_usage
        ), plan AS (
         SELECT p.customer_slug,
            p.plan_code,
            p.include_inbound_minutes,
            p.included_minutes,
            p.monthly_fee_ex_gst,
            p.overage_rate_per_minute,
            p.outbound_1300_rate_per_call,
            p.currency,
            p.effective_from,
            p.effective_to
           FROM public.v_billing_customer_plan_active p
        )
 SELECT u.customer_slug,
    u.billing_month,
    plan.plan_code,
    plan.currency,
    plan.included_minutes,
    u.total_minutes_used,
        CASE
            WHEN (u.total_minutes_used <= plan.included_minutes) THEN 'PASS'::text
            ELSE 'FAIL'::text
        END AS allowance_status,
    GREATEST((u.total_minutes_used - plan.included_minutes), (0)::bigint) AS overage_minutes,
    round(((GREATEST((u.total_minutes_used - plan.included_minutes), (0)::bigint))::numeric * plan.overage_rate_per_minute), 2) AS overage_charge_ex_gst,
    u.outbound_1300_calls,
    round(((u.outbound_1300_calls)::numeric * plan.outbound_1300_rate_per_call), 2) AS outbound_1300_charge_ex_gst,
    round(((plan.monthly_fee_ex_gst + ((GREATEST((u.total_minutes_used - plan.included_minutes), (0)::bigint))::numeric * plan.overage_rate_per_minute)) + ((u.outbound_1300_calls)::numeric * plan.outbound_1300_rate_per_call)), 2) AS total_charge_ex_gst
   FROM (u
     JOIN plan ON (((plan.customer_slug = u.customer_slug) AND (plan.effective_from <= u.billing_month) AND ((plan.effective_to IS NULL) OR (plan.effective_to > u.billing_month)))));


ALTER VIEW public.v_billing_monthly_invoice_lines OWNER TO metrics_writer;

--
-- Name: v_concurrency_calls_canonical; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_concurrency_calls_canonical AS
 SELECT id,
    customer_slug,
    account_id,
    direction,
    call_type,
    connect_ts,
    disconnect_ts
   FROM public.call_volume_records
  WHERE ((connect_ts IS NOT NULL) AND (disconnect_ts IS NOT NULL) AND (disconnect_ts > connect_ts) AND (call_length_sec > 0) AND (((direction = 'outbound'::text) AND (call_type = ANY (ARRAY['Local/National Calls'::text, 'Mobile Calls'::text, '13/1300 Numbers'::text, '1800 Numbers'::text, 'All Outbound'::text]))) OR ((direction = 'inbound'::text) AND (call_type = ANY (ARRAY['All Inbound'::text, '1300/1800 Inbound'::text])))));


ALTER VIEW public.v_concurrency_calls_canonical OWNER TO metrics_writer;

--
-- Name: v_concurrency_outbound_domestic; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_concurrency_outbound_domestic AS
 SELECT id,
    customer_slug,
    account_id,
    connect_ts,
    disconnect_ts,
    call_length_sec,
    call_type
   FROM public.call_volume_records
  WHERE ((direction = 'outbound'::text) AND (connect_ts IS NOT NULL) AND (disconnect_ts IS NOT NULL) AND (disconnect_ts > connect_ts) AND (call_length_sec > 0) AND (call_type = ANY (ARRAY['Local/National Calls'::text, 'Mobile Calls'::text])));


ALTER VIEW public.v_concurrency_outbound_domestic OWNER TO metrics_writer;

--
-- Name: v_manage_cfg_customers; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_manage_cfg_customers AS
 SELECT customer_slug,
    display_name,
    status
   FROM manage_cfg.customers;


ALTER VIEW public.v_manage_cfg_customers OWNER TO metrics_writer;

--
-- Name: v_manage_cfg_pbx; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_manage_cfg_pbx AS
 SELECT c.customer_slug,
    c.display_name AS customer_name,
    m.external_key AS pbx_fqdn,
    m.enabled,
    m.config_version,
    p.management_url,
    p.credentials_ref,
    p.verify_tls,
    p.polling_enabled,
    p.poll_interval_seconds
   FROM ((manage_cfg.modules m
     JOIN manage_cfg.customers c ON ((c.halo_customer_id = m.halo_customer_id)))
     JOIN manage_cfg.pbx_modules p ON ((p.module_id = m.module_id)))
  WHERE (m.module_type = 'PBX'::text);


ALTER VIEW public.v_manage_cfg_pbx OWNER TO metrics_writer;

--
-- Name: v_manage_cfg_trunk; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_manage_cfg_trunk AS
 SELECT c.customer_slug,
    c.display_name AS customer_name,
    m.external_key AS trunk_id,
    m.enabled,
    m.config_version,
    t.provider,
    t.credentials_ref,
    t.pbx_module_id,
    t.monitoring_enabled,
    t.concurrency_cap
   FROM ((manage_cfg.modules m
     JOIN manage_cfg.customers c ON ((c.halo_customer_id = m.halo_customer_id)))
     JOIN manage_cfg.trunk_modules t ON ((t.module_id = m.module_id)))
  WHERE (m.module_type = 'TRUNK'::text);


ALTER VIEW public.v_manage_cfg_trunk OWNER TO metrics_writer;

--
-- Name: v_pbx_current_status; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_pbx_current_status AS
 SELECT pi.id AS pbx_id,
    pi.customer_slug,
    pi.name,
    pi.base_url,
    l.status,
    l.last_seen_ts,
    l.last_change_ts,
    (EXISTS ( SELECT 1
           FROM public.pbx_maintenance_windows mw
          WHERE ((mw.pbx_id = pi.id) AND (mw.start_ts <= now()) AND (mw.end_ts >= now())))) AS in_maintenance
   FROM (public.pbx_instances pi
     LEFT JOIN public.pbx_status_latest l ON ((l.pbx_id = pi.id)));


ALTER VIEW public.v_pbx_current_status OWNER TO metrics_writer;

--
-- Name: v_pbx_multitenant_flag; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_pbx_multitenant_flag AS
 SELECT pbx_id,
        CASE
            WHEN is_multicompany THEN 'Yes'::text
            ELSE ''::text
        END AS multitenant_label
   FROM public.pbx_system_flags;


ALTER VIEW public.v_pbx_multitenant_flag OWNER TO metrics_writer;

--
-- Name: v_uptime_current_month; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_uptime_current_month AS
 SELECT pbx_id,
    month_start,
    uptime_pct_raw,
    uptime_pct_sla,
    observed_seconds,
    down_seconds_raw,
    maint_overlap_seconds,
    unknown_seconds,
    computed_at
   FROM public.pbx_uptime_monthly u
  WHERE (month_start = (date_trunc('month'::text, now()))::date);


ALTER VIEW public.v_uptime_current_month OWNER TO metrics_writer;

--
-- Name: v_uptime_history_monthly; Type: VIEW; Schema: public; Owner: metrics_writer
--

CREATE VIEW public.v_uptime_history_monthly AS
 SELECT u.pbx_id,
    u.month_start,
    u.observed_seconds,
    u.up_seconds_raw,
    u.down_seconds_raw,
    u.unknown_seconds,
    u.maint_overlap_seconds,
    u.down_seconds_sla,
    u.uptime_pct_raw,
    u.uptime_pct_sla,
    u.computed_at,
    pi.customer_slug,
    pi.name
   FROM (public.pbx_uptime_monthly u
     JOIN public.pbx_instances pi ON ((pi.id = u.pbx_id)))
  ORDER BY u.month_start DESC, pi.name;


ALTER VIEW public.v_uptime_history_monthly OWNER TO metrics_writer;

--
-- Name: alert_events id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.alert_events ALTER COLUMN id SET DEFAULT nextval('public.alert_events_id_seq'::regclass);


--
-- Name: call_cost_rates id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.call_cost_rates ALTER COLUMN id SET DEFAULT nextval('public.call_cost_rates_id_seq'::regclass);


--
-- Name: call_volume_records id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.call_volume_records ALTER COLUMN id SET DEFAULT nextval('public.call_volume_records_id_seq'::regclass);


--
-- Name: collector_3cx_session_probe id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.collector_3cx_session_probe ALTER COLUMN id SET DEFAULT nextval('public.collector_3cx_session_probe_id_seq'::regclass);


--
-- Name: collector_api_probe id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.collector_api_probe ALTER COLUMN id SET DEFAULT nextval('public.collector_api_probe_id_seq'::regclass);


--
-- Name: collector_heartbeat id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.collector_heartbeat ALTER COLUMN id SET DEFAULT nextval('public.collector_heartbeat_id_seq'::regclass);


--
-- Name: number_allocation_rates id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.number_allocation_rates ALTER COLUMN id SET DEFAULT nextval('public.number_allocation_rates_id_seq'::regclass);


--
-- Name: number_allocations id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.number_allocations ALTER COLUMN id SET DEFAULT nextval('public.number_allocations_id_seq'::regclass);


--
-- Name: pbx_audit_log id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_audit_log ALTER COLUMN id SET DEFAULT nextval('public.pbx_audit_log_id_seq'::regclass);


--
-- Name: pbx_instances id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_instances ALTER COLUMN id SET DEFAULT nextval('public.pbx_instances_id_seq'::regclass);


--
-- Name: pbx_maintenance_windows id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_maintenance_windows ALTER COLUMN id SET DEFAULT nextval('public.pbx_maintenance_windows_id_seq'::regclass);


--
-- Name: pbx_status_events id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_status_events ALTER COLUMN id SET DEFAULT nextval('public.pbx_status_events_id_seq'::regclass);


--
-- Name: trunk_concurrency_allocations id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.trunk_concurrency_allocations ALTER COLUMN id SET DEFAULT nextval('public.trunk_concurrency_allocations_id_seq'::regclass);


--
-- Name: trunk_concurrency_rates id; Type: DEFAULT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.trunk_concurrency_rates ALTER COLUMN id SET DEFAULT nextval('public.trunk_concurrency_rates_id_seq'::regclass);


--
-- Name: customer_halo_map customer_halo_map_halo_customer_id_key; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.customer_halo_map
    ADD CONSTRAINT customer_halo_map_halo_customer_id_key UNIQUE (halo_customer_id);


--
-- Name: customer_halo_map customer_halo_map_pkey; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.customer_halo_map
    ADD CONSTRAINT customer_halo_map_pkey PRIMARY KEY (customer_slug);


--
-- Name: customers customers_customer_slug_key; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.customers
    ADD CONSTRAINT customers_customer_slug_key UNIQUE (customer_slug);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (halo_customer_id);


--
-- Name: modules modules_pkey; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.modules
    ADD CONSTRAINT modules_pkey PRIMARY KEY (module_id);


--
-- Name: pbx_customer_map pbx_customer_map_pkey; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.pbx_customer_map
    ADD CONSTRAINT pbx_customer_map_pkey PRIMARY KEY (pbx_fqdn);


--
-- Name: pbx_modules pbx_modules_pbx_fqdn_key; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.pbx_modules
    ADD CONSTRAINT pbx_modules_pbx_fqdn_key UNIQUE (pbx_fqdn);


--
-- Name: pbx_modules pbx_modules_pkey; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.pbx_modules
    ADD CONSTRAINT pbx_modules_pkey PRIMARY KEY (module_id);


--
-- Name: trunk_import_stage trunk_import_stage_pkey; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.trunk_import_stage
    ADD CONSTRAINT trunk_import_stage_pkey PRIMARY KEY (trunk_id);


--
-- Name: trunk_modules trunk_modules_pkey; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.trunk_modules
    ADD CONSTRAINT trunk_modules_pkey PRIMARY KEY (module_id);


--
-- Name: trunk_modules trunk_modules_trunk_id_key; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.trunk_modules
    ADD CONSTRAINT trunk_modules_trunk_id_key UNIQUE (trunk_id);


--
-- Name: trunks_import_stage trunks_import_stage_pkey; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.trunks_import_stage
    ADD CONSTRAINT trunks_import_stage_pkey PRIMARY KEY (trunk_id);


--
-- Name: modules uq_modules_type_key; Type: CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.modules
    ADD CONSTRAINT uq_modules_type_key UNIQUE (module_type, external_key);


--
-- Name: active_calls_10m active_calls_10m_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.active_calls_10m
    ADD CONSTRAINT active_calls_10m_pkey PRIMARY KEY (pbx_id, bucket_ts);


--
-- Name: active_calls_1d active_calls_1d_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.active_calls_1d
    ADD CONSTRAINT active_calls_1d_pkey PRIMARY KEY (pbx_id, bucket_ts);


--
-- Name: active_calls_1h active_calls_1h_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.active_calls_1h
    ADD CONSTRAINT active_calls_1h_pkey PRIMARY KEY (pbx_id, bucket_ts);


--
-- Name: active_calls_1m active_calls_1m_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.active_calls_1m
    ADD CONSTRAINT active_calls_1m_pkey PRIMARY KEY (pbx_id, bucket_ts);


--
-- Name: active_calls_5m active_calls_5m_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.active_calls_5m
    ADD CONSTRAINT active_calls_5m_pkey PRIMARY KEY (pbx_id, bucket_ts);


--
-- Name: alert_events alert_events_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.alert_events
    ADD CONSTRAINT alert_events_pkey PRIMARY KEY (id);


--
-- Name: alert_state alert_state_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.alert_state
    ADD CONSTRAINT alert_state_pkey PRIMARY KEY (pbx_id, state_key);


--
-- Name: billing_customer_plan billing_customer_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.billing_customer_plan
    ADD CONSTRAINT billing_customer_plan_pkey PRIMARY KEY (customer_slug, effective_from);


--
-- Name: billing_plan_catalog billing_plan_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.billing_plan_catalog
    ADD CONSTRAINT billing_plan_catalog_pkey PRIMARY KEY (plan_code);


--
-- Name: call_cost_rates call_cost_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.call_cost_rates
    ADD CONSTRAINT call_cost_rates_pkey PRIMARY KEY (id);


--
-- Name: call_volume_records call_volume_records_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.call_volume_records
    ADD CONSTRAINT call_volume_records_pkey PRIMARY KEY (id);


--
-- Name: collector_3cx_session_probe collector_3cx_session_probe_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.collector_3cx_session_probe
    ADD CONSTRAINT collector_3cx_session_probe_pkey PRIMARY KEY (id);


--
-- Name: collector_api_probe collector_api_probe_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.collector_api_probe
    ADD CONSTRAINT collector_api_probe_pkey PRIMARY KEY (id);


--
-- Name: collector_heartbeat collector_heartbeat_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.collector_heartbeat
    ADD CONSTRAINT collector_heartbeat_pkey PRIMARY KEY (id);


--
-- Name: costing_trunk_exclusions costing_trunk_exclusions_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.costing_trunk_exclusions
    ADD CONSTRAINT costing_trunk_exclusions_pkey PRIMARY KEY (trunk_name);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (customer_slug);


--
-- Name: manage_audit_log manage_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.manage_audit_log
    ADD CONSTRAINT manage_audit_log_pkey PRIMARY KEY (audit_id);


--
-- Name: manage_customers manage_customers_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.manage_customers
    ADD CONSTRAINT manage_customers_pkey PRIMARY KEY (customer_slug);


--
-- Name: manage_pbxs manage_pbxs_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.manage_pbxs
    ADD CONSTRAINT manage_pbxs_pkey PRIMARY KEY (pbx_id);


--
-- Name: manage_trunks manage_trunks_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.manage_trunks
    ADD CONSTRAINT manage_trunks_pkey PRIMARY KEY (trunk_id);


--
-- Name: manage_users manage_users_email_key; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.manage_users
    ADD CONSTRAINT manage_users_email_key UNIQUE (email);


--
-- Name: manage_users manage_users_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.manage_users
    ADD CONSTRAINT manage_users_pkey PRIMARY KEY (user_id);


--
-- Name: metric_points metric_points_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_owner
--

ALTER TABLE ONLY public.metric_points
    ADD CONSTRAINT metric_points_pkey PRIMARY KEY (pbx_id, metric_name, ts);


--
-- Name: number_allocation_rates number_allocation_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.number_allocation_rates
    ADD CONSTRAINT number_allocation_rates_pkey PRIMARY KEY (id);


--
-- Name: number_allocations number_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.number_allocations
    ADD CONSTRAINT number_allocations_pkey PRIMARY KEY (id);


--
-- Name: outbound_call_duration_daily outbound_call_duration_daily_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.outbound_call_duration_daily
    ADD CONSTRAINT outbound_call_duration_daily_pkey PRIMARY KEY (call_date, customer_slug, account_id, call_type);


--
-- Name: outbound_call_duration_monthly outbound_call_duration_monthly_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.outbound_call_duration_monthly
    ADD CONSTRAINT outbound_call_duration_monthly_pkey PRIMARY KEY (month_start, customer_slug, account_id, call_type);


--
-- Name: outbound_total_cost_monthly outbound_total_cost_monthly_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.outbound_total_cost_monthly
    ADD CONSTRAINT outbound_total_cost_monthly_pkey PRIMARY KEY (month_start, account_id);


--
-- Name: pbx_audit_log pbx_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_audit_log
    ADD CONSTRAINT pbx_audit_log_pkey PRIMARY KEY (id);


--
-- Name: pbx_instances pbx_instances_base_url_key; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_instances
    ADD CONSTRAINT pbx_instances_base_url_key UNIQUE (base_url);


--
-- Name: pbx_instances pbx_instances_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_instances
    ADD CONSTRAINT pbx_instances_pkey PRIMARY KEY (id);


--
-- Name: pbx_maintenance_windows pbx_maint_no_overlap; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_maintenance_windows
    ADD CONSTRAINT pbx_maint_no_overlap EXCLUDE USING gist (pbx_id WITH =, tstzrange(start_ts, end_ts, '[)'::text) WITH &&);


--
-- Name: pbx_maintenance_windows pbx_maintenance_windows_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_maintenance_windows
    ADD CONSTRAINT pbx_maintenance_windows_pkey PRIMARY KEY (id);


--
-- Name: pbx_metric_latest pbx_metric_latest_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_metric_latest
    ADD CONSTRAINT pbx_metric_latest_pkey PRIMARY KEY (pbx_id, metric_name);


--
-- Name: pbx_status_events pbx_status_events_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_status_events
    ADD CONSTRAINT pbx_status_events_pkey PRIMARY KEY (id);


--
-- Name: pbx_status_latest pbx_status_latest_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_status_latest
    ADD CONSTRAINT pbx_status_latest_pkey PRIMARY KEY (pbx_id);


--
-- Name: pbx_system_flags pbx_system_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_system_flags
    ADD CONSTRAINT pbx_system_flags_pkey PRIMARY KEY (pbx_id);


--
-- Name: pbx_systems pbx_systems_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_systems
    ADD CONSTRAINT pbx_systems_pkey PRIMARY KEY (id);


--
-- Name: pbx_uptime_monthly pbx_uptime_monthly_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_uptime_monthly
    ADD CONSTRAINT pbx_uptime_monthly_pkey PRIMARY KEY (pbx_id, month_start);


--
-- Name: rollup_state rollup_state_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.rollup_state
    ADD CONSTRAINT rollup_state_pkey PRIMARY KEY (name);


--
-- Name: system_metadata system_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.system_metadata
    ADD CONSTRAINT system_metadata_pkey PRIMARY KEY (key);


--
-- Name: trunk_concurrency_allocations trunk_concurrency_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.trunk_concurrency_allocations
    ADD CONSTRAINT trunk_concurrency_allocations_pkey PRIMARY KEY (id);


--
-- Name: trunk_concurrency_rates trunk_concurrency_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.trunk_concurrency_rates
    ADD CONSTRAINT trunk_concurrency_rates_pkey PRIMARY KEY (id);


--
-- Name: trunks trunks_pkey; Type: CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.trunks
    ADD CONSTRAINT trunks_pkey PRIMARY KEY (trunk_id);


--
-- Name: idx_modules_customer; Type: INDEX; Schema: manage_cfg; Owner: metrics_writer
--

CREATE INDEX idx_modules_customer ON manage_cfg.modules USING btree (halo_customer_id);


--
-- Name: idx_modules_type; Type: INDEX; Schema: manage_cfg; Owner: metrics_writer
--

CREATE INDEX idx_modules_type ON manage_cfg.modules USING btree (module_type);


--
-- Name: active_calls_10m_time_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX active_calls_10m_time_idx ON public.active_calls_10m USING btree (bucket_ts DESC);


--
-- Name: active_calls_1d_time_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX active_calls_1d_time_idx ON public.active_calls_1d USING btree (bucket_ts DESC);


--
-- Name: active_calls_1h_time_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX active_calls_1h_time_idx ON public.active_calls_1h USING btree (bucket_ts DESC);


--
-- Name: active_calls_1m_time_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX active_calls_1m_time_idx ON public.active_calls_1m USING btree (bucket_ts DESC);


--
-- Name: active_calls_5m_time_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX active_calls_5m_time_idx ON public.active_calls_5m USING btree (bucket_ts DESC);


--
-- Name: idx_call_cost_rates_lookup; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_call_cost_rates_lookup ON public.call_cost_rates USING btree (carrier_name, trunk_name, call_type, effective_from);


--
-- Name: idx_callvol_connect_ts; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_callvol_connect_ts ON public.call_volume_records USING btree (connect_ts);


--
-- Name: idx_callvol_customer; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_callvol_customer ON public.call_volume_records USING btree (customer_slug);


--
-- Name: idx_callvol_date; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_callvol_date ON public.call_volume_records USING btree (call_date);


--
-- Name: idx_callvol_dir; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_callvol_dir ON public.call_volume_records USING btree (direction);


--
-- Name: idx_callvol_type; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_callvol_type ON public.call_volume_records USING btree (call_type);


--
-- Name: idx_customers_status; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_customers_status ON public.customers USING btree (status);


--
-- Name: idx_metric_points_metric_ts; Type: INDEX; Schema: public; Owner: metrics_owner
--

CREATE INDEX idx_metric_points_metric_ts ON public.metric_points USING btree (metric_name, ts DESC);


--
-- Name: idx_metric_points_pbx_metric_ts; Type: INDEX; Schema: public; Owner: metrics_owner
--

CREATE INDEX idx_metric_points_pbx_metric_ts ON public.metric_points USING btree (pbx_id, metric_name, ts DESC);


--
-- Name: idx_outbound_daily_date; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_outbound_daily_date ON public.outbound_call_duration_daily USING btree (call_date);


--
-- Name: idx_outbound_monthly_month; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_outbound_monthly_month ON public.outbound_call_duration_monthly USING btree (month_start);


--
-- Name: idx_pbx_mw_active; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_pbx_mw_active ON public.pbx_maintenance_windows USING btree (pbx_id, start_ts DESC, end_ts);


--
-- Name: idx_trunks_customer; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_trunks_customer ON public.trunks USING btree (customer_slug);


--
-- Name: idx_trunks_pbx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_trunks_pbx ON public.trunks USING btree (pbx_id);


--
-- Name: idx_trunks_type; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX idx_trunks_type ON public.trunks USING btree (trunk_type);


--
-- Name: pbx_maint_pbx_time_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX pbx_maint_pbx_time_idx ON public.pbx_maintenance_windows USING btree (pbx_id, start_ts, end_ts);


--
-- Name: pbx_metric_latest_metric_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX pbx_metric_latest_metric_idx ON public.pbx_metric_latest USING btree (metric_name);


--
-- Name: pbx_status_events_pbx_ts_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX pbx_status_events_pbx_ts_idx ON public.pbx_status_events USING btree (pbx_id, ts DESC);


--
-- Name: pbx_status_events_ts_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX pbx_status_events_ts_idx ON public.pbx_status_events USING btree (ts DESC);


--
-- Name: pbx_uptime_monthly_month_idx; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE INDEX pbx_uptime_monthly_month_idx ON public.pbx_uptime_monthly USING btree (month_start DESC);


--
-- Name: ux_call_volume_record_hash; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE UNIQUE INDEX ux_call_volume_record_hash ON public.call_volume_records USING btree (record_hash);


--
-- Name: ux_number_allocation_rates; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE UNIQUE INDEX ux_number_allocation_rates ON public.number_allocation_rates USING btree (carrier_name, number_type, effective_from);


--
-- Name: ux_number_allocations; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE UNIQUE INDEX ux_number_allocations ON public.number_allocations USING btree (carrier_name, account_id, number_type, effective_from);


--
-- Name: ux_trunk_concurrency_allocations; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE UNIQUE INDEX ux_trunk_concurrency_allocations ON public.trunk_concurrency_allocations USING btree (carrier_name, trunk_name, effective_from);


--
-- Name: ux_trunk_concurrency_rates; Type: INDEX; Schema: public; Owner: metrics_writer
--

CREATE UNIQUE INDEX ux_trunk_concurrency_rates ON public.trunk_concurrency_rates USING btree (carrier_name, trunk_name, effective_from);


--
-- Name: metric_points trg_block_metric_points_delete; Type: TRIGGER; Schema: public; Owner: metrics_owner
--

CREATE TRIGGER trg_block_metric_points_delete BEFORE DELETE ON public.metric_points FOR EACH ROW EXECUTE FUNCTION public.fn_block_metric_points_mutation();


--
-- Name: metric_points trg_block_metric_points_update; Type: TRIGGER; Schema: public; Owner: metrics_owner
--

CREATE TRIGGER trg_block_metric_points_update BEFORE UPDATE ON public.metric_points FOR EACH ROW EXECUTE FUNCTION public.fn_block_metric_points_mutation();


--
-- Name: modules modules_halo_customer_id_fkey; Type: FK CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.modules
    ADD CONSTRAINT modules_halo_customer_id_fkey FOREIGN KEY (halo_customer_id) REFERENCES manage_cfg.customers(halo_customer_id) ON DELETE CASCADE;


--
-- Name: pbx_modules pbx_modules_module_id_fkey; Type: FK CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.pbx_modules
    ADD CONSTRAINT pbx_modules_module_id_fkey FOREIGN KEY (module_id) REFERENCES manage_cfg.modules(module_id) ON DELETE CASCADE;


--
-- Name: trunk_modules trunk_modules_module_id_fkey; Type: FK CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.trunk_modules
    ADD CONSTRAINT trunk_modules_module_id_fkey FOREIGN KEY (module_id) REFERENCES manage_cfg.modules(module_id) ON DELETE CASCADE;


--
-- Name: trunk_modules trunk_modules_pbx_module_id_fkey; Type: FK CONSTRAINT; Schema: manage_cfg; Owner: metrics_writer
--

ALTER TABLE ONLY manage_cfg.trunk_modules
    ADD CONSTRAINT trunk_modules_pbx_module_id_fkey FOREIGN KEY (pbx_module_id) REFERENCES manage_cfg.pbx_modules(module_id) ON DELETE SET NULL;


--
-- Name: alert_events alert_events_pbx_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.alert_events
    ADD CONSTRAINT alert_events_pbx_id_fkey FOREIGN KEY (pbx_id) REFERENCES public.pbx_instances(id) ON DELETE CASCADE;


--
-- Name: alert_state alert_state_pbx_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.alert_state
    ADD CONSTRAINT alert_state_pbx_id_fkey FOREIGN KEY (pbx_id) REFERENCES public.pbx_instances(id) ON DELETE CASCADE;


--
-- Name: billing_customer_plan billing_customer_plan_plan_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.billing_customer_plan
    ADD CONSTRAINT billing_customer_plan_plan_code_fkey FOREIGN KEY (plan_code) REFERENCES public.billing_plan_catalog(plan_code);


--
-- Name: pbx_systems fk_pbx_systems_customer; Type: FK CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.pbx_systems
    ADD CONSTRAINT fk_pbx_systems_customer FOREIGN KEY (customer_slug) REFERENCES public.customers(customer_slug);


--
-- Name: manage_customers manage_customers_customer_slug_fkey; Type: FK CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.manage_customers
    ADD CONSTRAINT manage_customers_customer_slug_fkey FOREIGN KEY (customer_slug) REFERENCES public.customers(customer_slug) ON DELETE CASCADE;


--
-- Name: manage_pbxs manage_pbxs_customer_slug_fkey; Type: FK CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.manage_pbxs
    ADD CONSTRAINT manage_pbxs_customer_slug_fkey FOREIGN KEY (customer_slug) REFERENCES public.customers(customer_slug) ON DELETE RESTRICT;


--
-- Name: manage_trunks manage_trunks_customer_slug_fkey; Type: FK CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.manage_trunks
    ADD CONSTRAINT manage_trunks_customer_slug_fkey FOREIGN KEY (customer_slug) REFERENCES public.customers(customer_slug) ON DELETE RESTRICT;


--
-- Name: metric_points metric_points_pbx_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: metrics_owner
--

ALTER TABLE ONLY public.metric_points
    ADD CONSTRAINT metric_points_pbx_id_fkey FOREIGN KEY (pbx_id) REFERENCES public.pbx_instances(id) ON DELETE CASCADE;


--
-- Name: trunks trunks_customer_slug_fkey; Type: FK CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.trunks
    ADD CONSTRAINT trunks_customer_slug_fkey FOREIGN KEY (customer_slug) REFERENCES public.customers(customer_slug);


--
-- Name: trunks trunks_pbx_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: metrics_writer
--

ALTER TABLE ONLY public.trunks
    ADD CONSTRAINT trunks_pbx_id_fkey FOREIGN KEY (pbx_id) REFERENCES public.pbx_systems(id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT USAGE ON SCHEMA public TO collector_writer;
GRANT USAGE ON SCHEMA public TO metrics_writer;
GRANT USAGE ON SCHEMA public TO metrics_ingest;


--
-- Name: FUNCTION fn_record_pbx_status(p_pbx_id bigint, p_status text, p_ts timestamp with time zone, p_error jsonb, p_heartbeat boolean, p_heartbeat_every_seconds integer); Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT ALL ON FUNCTION public.fn_record_pbx_status(p_pbx_id bigint, p_status text, p_ts timestamp with time zone, p_error jsonb, p_heartbeat boolean, p_heartbeat_every_seconds integer) TO metrics_ingest;


--
-- Name: TABLE active_calls_10m; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.active_calls_10m FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.active_calls_10m TO metrics_writer;
GRANT SELECT ON TABLE public.active_calls_10m TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.active_calls_10m TO metrics_ingest;


--
-- Name: TABLE active_calls_1d; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.active_calls_1d FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.active_calls_1d TO metrics_writer;
GRANT SELECT ON TABLE public.active_calls_1d TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.active_calls_1d TO metrics_ingest;


--
-- Name: TABLE active_calls_1h; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.active_calls_1h FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.active_calls_1h TO metrics_writer;
GRANT SELECT ON TABLE public.active_calls_1h TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.active_calls_1h TO metrics_ingest;


--
-- Name: TABLE active_calls_1m; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.active_calls_1m FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.active_calls_1m TO metrics_writer;
GRANT SELECT ON TABLE public.active_calls_1m TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.active_calls_1m TO metrics_ingest;


--
-- Name: TABLE active_calls_5m; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.active_calls_5m FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.active_calls_5m TO metrics_writer;
GRANT SELECT ON TABLE public.active_calls_5m TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.active_calls_5m TO metrics_ingest;


--
-- Name: TABLE alert_events; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.alert_events FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.alert_events TO metrics_writer;
GRANT SELECT ON TABLE public.alert_events TO grafana_reader;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.alert_events TO collector_writer;
GRANT SELECT,INSERT,UPDATE ON TABLE public.alert_events TO metrics_ingest;


--
-- Name: SEQUENCE alert_events_id_seq; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON SEQUENCE public.alert_events_id_seq FROM metrics_writer;
GRANT SELECT,USAGE ON SEQUENCE public.alert_events_id_seq TO metrics_writer;
GRANT SELECT ON SEQUENCE public.alert_events_id_seq TO grafana_reader;
GRANT SELECT,USAGE ON SEQUENCE public.alert_events_id_seq TO metrics_ingest;


--
-- Name: TABLE alert_state; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.alert_state FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.alert_state TO metrics_writer;
GRANT SELECT ON TABLE public.alert_state TO grafana_reader;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.alert_state TO collector_writer;
GRANT SELECT,INSERT,UPDATE ON TABLE public.alert_state TO metrics_ingest;


--
-- Name: TABLE audit_number_allocation_rates_after_20260406; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.audit_number_allocation_rates_after_20260406 TO grafana_reader;


--
-- Name: TABLE audit_number_allocation_rates_before_20260406; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.audit_number_allocation_rates_before_20260406 TO grafana_reader;


--
-- Name: TABLE billing_customer_plan; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.billing_customer_plan TO grafana_reader;


--
-- Name: TABLE billing_plan_catalog; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.billing_plan_catalog TO grafana_reader;


--
-- Name: TABLE call_cost_rates; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.call_cost_rates TO grafana_reader;


--
-- Name: TABLE call_volume_records; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.call_volume_records FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.call_volume_records TO metrics_writer;
GRANT SELECT ON TABLE public.call_volume_records TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.call_volume_records TO metrics_ingest;


--
-- Name: SEQUENCE call_volume_records_id_seq; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON SEQUENCE public.call_volume_records_id_seq FROM metrics_writer;
GRANT SELECT,USAGE ON SEQUENCE public.call_volume_records_id_seq TO metrics_writer;
GRANT SELECT,USAGE ON SEQUENCE public.call_volume_records_id_seq TO metrics_ingest;


--
-- Name: TABLE call_volume_records_stage; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.call_volume_records_stage FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.call_volume_records_stage TO metrics_writer;
GRANT SELECT ON TABLE public.call_volume_records_stage TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.call_volume_records_stage TO metrics_ingest;


--
-- Name: TABLE collector_3cx_session_probe; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.collector_3cx_session_probe TO grafana_reader;


--
-- Name: TABLE collector_api_probe; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.collector_api_probe TO grafana_reader;


--
-- Name: TABLE collector_heartbeat; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.collector_heartbeat TO grafana_reader;


--
-- Name: TABLE costing_trunk_exclusions; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.costing_trunk_exclusions TO grafana_reader;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.customers TO grafana_reader;


--
-- Name: TABLE manage_audit_log; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.manage_audit_log TO grafana_reader;


--
-- Name: TABLE manage_customers; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.manage_customers TO grafana_reader;


--
-- Name: TABLE manage_pbxs; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.manage_pbxs TO grafana_reader;


--
-- Name: TABLE manage_trunks; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.manage_trunks TO grafana_reader;


--
-- Name: TABLE manage_users; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.manage_users TO grafana_reader;


--
-- Name: TABLE metric_points; Type: ACL; Schema: public; Owner: metrics_owner
--

REVOKE ALL ON TABLE public.metric_points FROM metrics_owner;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.metric_points TO metrics_owner;
GRANT SELECT ON TABLE public.metric_points TO grafana_reader;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.metric_points TO collector_writer;
GRANT SELECT,INSERT ON TABLE public.metric_points TO metrics_writer;
GRANT SELECT,INSERT,UPDATE ON TABLE public.metric_points TO metrics_ingest;


--
-- Name: TABLE number_allocation_rates; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.number_allocation_rates TO grafana_reader;


--
-- Name: TABLE number_allocations; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.number_allocations TO grafana_reader;


--
-- Name: TABLE outbound_call_duration_daily; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.outbound_call_duration_daily TO grafana_reader;


--
-- Name: TABLE outbound_call_duration_monthly; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.outbound_call_duration_monthly TO grafana_reader;


--
-- Name: TABLE outbound_total_cost_monthly; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.outbound_total_cost_monthly TO grafana_reader;


--
-- Name: TABLE pbx_audit_log; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.pbx_audit_log TO grafana_reader;


--
-- Name: TABLE pbx_instances; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.pbx_instances FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.pbx_instances TO metrics_writer;
GRANT SELECT ON TABLE public.pbx_instances TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.pbx_instances TO collector_writer;
GRANT SELECT,INSERT,UPDATE ON TABLE public.pbx_instances TO metrics_ingest;


--
-- Name: SEQUENCE pbx_instances_id_seq; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON SEQUENCE public.pbx_instances_id_seq FROM metrics_writer;
GRANT SELECT,USAGE ON SEQUENCE public.pbx_instances_id_seq TO metrics_writer;
GRANT SELECT ON SEQUENCE public.pbx_instances_id_seq TO grafana_reader;
GRANT SELECT,USAGE ON SEQUENCE public.pbx_instances_id_seq TO metrics_ingest;


--
-- Name: TABLE pbx_maintenance_windows; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.pbx_maintenance_windows FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.pbx_maintenance_windows TO metrics_writer;
GRANT SELECT ON TABLE public.pbx_maintenance_windows TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.pbx_maintenance_windows TO metrics_ingest;


--
-- Name: SEQUENCE pbx_maintenance_windows_id_seq; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON SEQUENCE public.pbx_maintenance_windows_id_seq FROM metrics_writer;
GRANT SELECT,USAGE ON SEQUENCE public.pbx_maintenance_windows_id_seq TO metrics_writer;
GRANT SELECT,USAGE ON SEQUENCE public.pbx_maintenance_windows_id_seq TO metrics_ingest;


--
-- Name: TABLE pbx_metric_latest; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.pbx_metric_latest FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.pbx_metric_latest TO metrics_writer;
GRANT SELECT ON TABLE public.pbx_metric_latest TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.pbx_metric_latest TO metrics_ingest;


--
-- Name: TABLE pbx_systems; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.pbx_systems TO grafana_reader;


--
-- Name: TABLE pbx_poll_targets; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.pbx_poll_targets TO grafana_reader;


--
-- Name: TABLE pbx_status_events; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.pbx_status_events FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.pbx_status_events TO metrics_writer;
GRANT SELECT ON TABLE public.pbx_status_events TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.pbx_status_events TO metrics_ingest;


--
-- Name: SEQUENCE pbx_status_events_id_seq; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON SEQUENCE public.pbx_status_events_id_seq FROM metrics_writer;
GRANT SELECT,USAGE ON SEQUENCE public.pbx_status_events_id_seq TO metrics_writer;
GRANT ALL ON SEQUENCE public.pbx_status_events_id_seq TO metrics_ingest;


--
-- Name: TABLE pbx_status_latest; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.pbx_status_latest FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.pbx_status_latest TO metrics_writer;
GRANT SELECT ON TABLE public.pbx_status_latest TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.pbx_status_latest TO metrics_ingest;


--
-- Name: TABLE pbx_system_flags; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.pbx_system_flags FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.pbx_system_flags TO metrics_writer;
GRANT SELECT ON TABLE public.pbx_system_flags TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.pbx_system_flags TO metrics_ingest;


--
-- Name: TABLE pbx_uptime_monthly; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.pbx_uptime_monthly FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.pbx_uptime_monthly TO metrics_writer;
GRANT SELECT ON TABLE public.pbx_uptime_monthly TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.pbx_uptime_monthly TO metrics_ingest;


--
-- Name: TABLE rollup_state; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.rollup_state FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.rollup_state TO metrics_writer;
GRANT SELECT ON TABLE public.rollup_state TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.rollup_state TO metrics_ingest;


--
-- Name: TABLE stg_breeze_numbers; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.stg_breeze_numbers TO grafana_reader;


--
-- Name: TABLE system_metadata; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.system_metadata TO grafana_reader;


--
-- Name: TABLE trunk_concurrency_allocations; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.trunk_concurrency_allocations TO grafana_reader;


--
-- Name: TABLE trunk_concurrency_rates; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.trunk_concurrency_rates TO grafana_reader;


--
-- Name: TABLE trunks; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.trunks TO grafana_reader;


--
-- Name: TABLE v_admin_pbx_overview; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_admin_pbx_overview TO grafana_reader;


--
-- Name: TABLE v_billing_calls_deduped; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_billing_calls_deduped TO grafana_reader;


--
-- Name: TABLE v_billing_calls_classified; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_billing_calls_classified TO grafana_reader;


--
-- Name: TABLE v_billing_customer_plan_active; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_billing_customer_plan_active TO grafana_reader;


--
-- Name: TABLE v_billing_monthly_usage; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_billing_monthly_usage TO grafana_reader;


--
-- Name: TABLE v_billing_monthly_invoice_lines; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_billing_monthly_invoice_lines TO grafana_reader;


--
-- Name: TABLE v_concurrency_calls_canonical; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_concurrency_calls_canonical TO grafana_reader;


--
-- Name: TABLE v_concurrency_outbound_domestic; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_concurrency_outbound_domestic TO grafana_reader;


--
-- Name: TABLE v_manage_cfg_customers; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_manage_cfg_customers TO grafana_reader;


--
-- Name: TABLE v_manage_cfg_pbx; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_manage_cfg_pbx TO grafana_reader;


--
-- Name: TABLE v_manage_cfg_trunk; Type: ACL; Schema: public; Owner: metrics_writer
--

GRANT SELECT ON TABLE public.v_manage_cfg_trunk TO grafana_reader;


--
-- Name: TABLE v_pbx_current_status; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.v_pbx_current_status FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.v_pbx_current_status TO metrics_writer;
GRANT SELECT ON TABLE public.v_pbx_current_status TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.v_pbx_current_status TO metrics_ingest;


--
-- Name: TABLE v_pbx_multitenant_flag; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.v_pbx_multitenant_flag FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.v_pbx_multitenant_flag TO metrics_writer;
GRANT SELECT ON TABLE public.v_pbx_multitenant_flag TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.v_pbx_multitenant_flag TO metrics_ingest;


--
-- Name: TABLE v_uptime_current_month; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.v_uptime_current_month FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.v_uptime_current_month TO metrics_writer;
GRANT SELECT ON TABLE public.v_uptime_current_month TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.v_uptime_current_month TO metrics_ingest;


--
-- Name: TABLE v_uptime_history_monthly; Type: ACL; Schema: public; Owner: metrics_writer
--

REVOKE ALL ON TABLE public.v_uptime_history_monthly FROM metrics_writer;
GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE public.v_uptime_history_monthly TO metrics_writer;
GRANT SELECT ON TABLE public.v_uptime_history_monthly TO grafana_reader;
GRANT SELECT,INSERT,UPDATE ON TABLE public.v_uptime_history_monthly TO metrics_ingest;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: metrics_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE metrics_owner IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO metrics_ingest;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: metrics_owner
--

ALTER DEFAULT PRIVILEGES FOR ROLE metrics_owner IN SCHEMA public GRANT SELECT,INSERT,UPDATE ON TABLES TO metrics_ingest;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: metrics_writer
--

ALTER DEFAULT PRIVILEGES FOR ROLE metrics_writer IN SCHEMA public GRANT SELECT ON TABLES TO grafana_reader;


--
-- PostgreSQL database dump complete
--

\unrestrict blUf1jn7ced1Lsl2ueg35P10gjoFLy4760J0ByKy3gvo74cuNF0ckPfbgsVsGDt

