--
-- PostgreSQL database dump
--

\restrict AQV1JocMmV6PB4AuEnek9Nee008508OWl4pnQukPATStn7Q0HBpg9rj2rzzxPfe

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
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: disable_pbx_polling_by_base_url(text); Type: FUNCTION; Schema: public; Owner: secrets_admin
--

CREATE FUNCTION public.disable_pbx_polling_by_base_url(p_base_url text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE pbx_3cx
    SET polling_enabled = false
    WHERE base_url = p_base_url;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pbx_3cx record not found for base_url: %', p_base_url;
    END IF;
END;
$$;


ALTER FUNCTION public.disable_pbx_polling_by_base_url(p_base_url text) OWNER TO secrets_admin;

--
-- Name: enable_pbx_polling(text); Type: FUNCTION; Schema: public; Owner: secrets_admin
--

CREATE FUNCTION public.enable_pbx_polling(p_pbx_name text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_base_url text;
BEGIN
    -- Resolve base_url from pbx_instances (metrics DB reference)
    SELECT base_url
    INTO v_base_url
    FROM pbx_instances
    WHERE name = p_pbx_name;

    IF v_base_url IS NULL THEN
        RAISE EXCEPTION 'PBX not found: %', p_pbx_name;
    END IF;

    -- Enable polling in pbx_3cx (secrets DB)
    UPDATE pbx_3cx
    SET polling_enabled = true
    WHERE base_url = v_base_url;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pbx_3cx record not found for base_url: %', v_base_url;
    END IF;
END;
$$;


ALTER FUNCTION public.enable_pbx_polling(p_pbx_name text) OWNER TO secrets_admin;

--
-- Name: enable_pbx_polling_by_base_url(text); Type: FUNCTION; Schema: public; Owner: secrets_admin
--

CREATE FUNCTION public.enable_pbx_polling_by_base_url(p_base_url text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE pbx_3cx
    SET polling_enabled = true
    WHERE base_url = p_base_url;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'pbx_3cx record not found for base_url: %', p_base_url;
    END IF;
END;
$$;


ALTER FUNCTION public.enable_pbx_polling_by_base_url(p_base_url text) OWNER TO secrets_admin;

--
-- Name: fn_upsert_pbx_3cx(bigint, text, boolean, text, text, text, text); Type: FUNCTION; Schema: public; Owner: secrets_admin
--

CREATE FUNCTION public.fn_upsert_pbx_3cx(p_customer_id bigint, p_base_url text, p_verify_tls boolean, p_username text, p_password text, p_mfa text, p_master_key text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO public.pbx_3cx (customer_id, base_url, verify_tls, username_enc, password_enc, mfa_enc)
  VALUES (
    p_customer_id,
    p_base_url,
    COALESCE(p_verify_tls, true),
    CASE WHEN p_username IS NULL OR btrim(p_username) = '' THEN NULL
         ELSE pgp_sym_encrypt(p_username, p_master_key, 'cipher-algo=aes256, compress-algo=1') END,
    CASE WHEN p_password IS NULL OR btrim(p_password) = '' THEN NULL
         ELSE pgp_sym_encrypt(p_password, p_master_key, 'cipher-algo=aes256, compress-algo=1') END,
    CASE WHEN p_mfa IS NULL OR btrim(p_mfa) = '' THEN NULL
         ELSE pgp_sym_encrypt(p_mfa, p_master_key, 'cipher-algo=aes256, compress-algo=1') END
  )
  ON CONFLICT (base_url) DO UPDATE
  SET customer_id = EXCLUDED.customer_id,
      verify_tls  = EXCLUDED.verify_tls,
      username_enc = COALESCE(EXCLUDED.username_enc, public.pbx_3cx.username_enc),
      password_enc = COALESCE(EXCLUDED.password_enc, public.pbx_3cx.password_enc),
      mfa_enc      = COALESCE(EXCLUDED.mfa_enc, public.pbx_3cx.mfa_enc);
END;
$$;


ALTER FUNCTION public.fn_upsert_pbx_3cx(p_customer_id bigint, p_base_url text, p_verify_tls boolean, p_username text, p_password text, p_mfa text, p_master_key text) OWNER TO secrets_admin;

--
-- Name: safe_pgp_sym_decrypt(bytea, text); Type: FUNCTION; Schema: public; Owner: secrets_admin
--

CREATE FUNCTION public.safe_pgp_sym_decrypt(data bytea, key text) RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN pgp_sym_decrypt(data, key);
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;


ALTER FUNCTION public.safe_pgp_sym_decrypt(data bytea, key text) OWNER TO secrets_admin;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: cdr_import_batches; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.cdr_import_batches (
    id integer NOT NULL,
    filename text NOT NULL,
    file_hash text NOT NULL,
    imported_at timestamp without time zone DEFAULT now(),
    rows_total integer,
    rows_accepted integer,
    rows_rejected integer
);


ALTER TABLE public.cdr_import_batches OWNER TO secrets_admin;

--
-- Name: cdr_import_batches_id_seq; Type: SEQUENCE; Schema: public; Owner: secrets_admin
--

CREATE SEQUENCE public.cdr_import_batches_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.cdr_import_batches_id_seq OWNER TO secrets_admin;

--
-- Name: cdr_import_batches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: secrets_admin
--

ALTER SEQUENCE public.cdr_import_batches_id_seq OWNED BY public.cdr_import_batches.id;


--
-- Name: cdr_import_rejects; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.cdr_import_rejects (
    id bigint NOT NULL,
    batch_id integer,
    source_file text,
    raw_row text,
    reject_reason text,
    rejected_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.cdr_import_rejects OWNER TO secrets_admin;

--
-- Name: cdr_import_rejects_id_seq; Type: SEQUENCE; Schema: public; Owner: secrets_admin
--

CREATE SEQUENCE public.cdr_import_rejects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.cdr_import_rejects_id_seq OWNER TO secrets_admin;

--
-- Name: cdr_import_rejects_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: secrets_admin
--

ALTER SEQUENCE public.cdr_import_rejects_id_seq OWNED BY public.cdr_import_rejects.id;


--
-- Name: cdr_provider_calls; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.cdr_provider_calls (
    id bigint NOT NULL,
    batch_id integer NOT NULL,
    source_file text NOT NULL,
    account_id text NOT NULL,
    cli text,
    cld text,
    country text,
    description text,
    connect_time timestamp without time zone NOT NULL,
    disconnect_time timestamp without time zone,
    duration_sec integer NOT NULL,
    charged_amount numeric(10,4) DEFAULT 0 NOT NULL,
    imported_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT cdr_provider_calls_duration_sec_check CHECK ((duration_sec >= 0))
);


ALTER TABLE public.cdr_provider_calls OWNER TO secrets_admin;

--
-- Name: cdr_provider_calls_id_seq; Type: SEQUENCE; Schema: public; Owner: secrets_admin
--

CREATE SEQUENCE public.cdr_provider_calls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.cdr_provider_calls_id_seq OWNER TO secrets_admin;

--
-- Name: cdr_provider_calls_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: secrets_admin
--

ALTER SEQUENCE public.cdr_provider_calls_id_seq OWNED BY public.cdr_provider_calls.id;


--
-- Name: customer_3cx_pbx; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.customer_3cx_pbx (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    name text NOT NULL,
    base_url text NOT NULL,
    verify_tls boolean DEFAULT true NOT NULL,
    alert_email text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.customer_3cx_pbx OWNER TO secrets_admin;

--
-- Name: customer_3cx_pbx_id_seq; Type: SEQUENCE; Schema: public; Owner: secrets_admin
--

CREATE SEQUENCE public.customer_3cx_pbx_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customer_3cx_pbx_id_seq OWNER TO secrets_admin;

--
-- Name: customer_3cx_pbx_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: secrets_admin
--

ALTER SEQUENCE public.customer_3cx_pbx_id_seq OWNED BY public.customer_3cx_pbx.id;


--
-- Name: customer_call_trunks; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.customer_call_trunks (
    id bigint NOT NULL,
    customer_id integer NOT NULL,
    account_id text NOT NULL,
    trunk_label text DEFAULT ''::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.customer_call_trunks OWNER TO secrets_admin;

--
-- Name: customer_call_trunks_id_seq; Type: SEQUENCE; Schema: public; Owner: secrets_admin
--

CREATE SEQUENCE public.customer_call_trunks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customer_call_trunks_id_seq OWNER TO secrets_admin;

--
-- Name: customer_call_trunks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: secrets_admin
--

ALTER SEQUENCE public.customer_call_trunks_id_seq OWNED BY public.customer_call_trunks.id;


--
-- Name: customer_modules; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.customer_modules (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    module_id bigint NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    config_json jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.customer_modules OWNER TO secrets_admin;

--
-- Name: customer_modules_id_seq; Type: SEQUENCE; Schema: public; Owner: secrets_admin
--

CREATE SEQUENCE public.customer_modules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customer_modules_id_seq OWNER TO secrets_admin;

--
-- Name: customer_modules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: secrets_admin
--

ALTER SEQUENCE public.customer_modules_id_seq OWNED BY public.customer_modules.id;


--
-- Name: customers; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.customers (
    id bigint NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    halo_alias text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    active boolean DEFAULT true NOT NULL,
    alert_email text DEFAULT ''::text NOT NULL
);


ALTER TABLE public.customers OWNER TO secrets_admin;

--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: secrets_admin
--

CREATE SEQUENCE public.customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customers_id_seq OWNER TO secrets_admin;

--
-- Name: customers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: secrets_admin
--

ALTER SEQUENCE public.customers_id_seq OWNED BY public.customers.id;


--
-- Name: encrypted_secrets; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.encrypted_secrets (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    module_id bigint NOT NULL,
    secret_name text NOT NULL,
    secret_ciphertext bytea NOT NULL,
    secret_meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.encrypted_secrets OWNER TO secrets_admin;

--
-- Name: encrypted_secrets_id_seq; Type: SEQUENCE; Schema: public; Owner: secrets_admin
--

CREATE SEQUENCE public.encrypted_secrets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.encrypted_secrets_id_seq OWNER TO secrets_admin;

--
-- Name: encrypted_secrets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: secrets_admin
--

ALTER SEQUENCE public.encrypted_secrets_id_seq OWNED BY public.encrypted_secrets.id;


--
-- Name: modules; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.modules (
    id bigint NOT NULL,
    module_key text NOT NULL,
    display_name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    active boolean DEFAULT true NOT NULL
);


ALTER TABLE public.modules OWNER TO secrets_admin;

--
-- Name: modules_id_seq; Type: SEQUENCE; Schema: public; Owner: secrets_admin
--

CREATE SEQUENCE public.modules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.modules_id_seq OWNER TO secrets_admin;

--
-- Name: modules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: secrets_admin
--

ALTER SEQUENCE public.modules_id_seq OWNED BY public.modules.id;


--
-- Name: pbx_3cx; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.pbx_3cx (
    customer_id bigint,
    base_url text NOT NULL,
    verify_tls boolean DEFAULT true,
    username_enc bytea,
    password_enc bytea,
    mfa_enc bytea,
    polling_enabled boolean DEFAULT true NOT NULL
);


ALTER TABLE public.pbx_3cx OWNER TO secrets_admin;

--
-- Name: staging_customer_trunks; Type: TABLE; Schema: public; Owner: secrets_admin
--

CREATE TABLE public.staging_customer_trunks (
    customer_name text,
    account_id text
);


ALTER TABLE public.staging_customer_trunks OWNER TO secrets_admin;

--
-- Name: v_trunk_inventory_export; Type: VIEW; Schema: public; Owner: secrets_admin
--

CREATE VIEW public.v_trunk_inventory_export AS
 SELECT c.halo_alias AS halo_customer_id,
    c.slug AS customer_slug,
    t.account_id AS trunk_id,
    NULL::text AS provider,
    NULL::integer AS concurrency_cap,
    t.active AS enabled
   FROM (public.customer_call_trunks t
     JOIN public.customers c ON ((c.id = t.customer_id)));


ALTER VIEW public.v_trunk_inventory_export OWNER TO secrets_admin;

--
-- Name: cdr_import_batches id; Type: DEFAULT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.cdr_import_batches ALTER COLUMN id SET DEFAULT nextval('public.cdr_import_batches_id_seq'::regclass);


--
-- Name: cdr_import_rejects id; Type: DEFAULT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.cdr_import_rejects ALTER COLUMN id SET DEFAULT nextval('public.cdr_import_rejects_id_seq'::regclass);


--
-- Name: cdr_provider_calls id; Type: DEFAULT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.cdr_provider_calls ALTER COLUMN id SET DEFAULT nextval('public.cdr_provider_calls_id_seq'::regclass);


--
-- Name: customer_3cx_pbx id; Type: DEFAULT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_3cx_pbx ALTER COLUMN id SET DEFAULT nextval('public.customer_3cx_pbx_id_seq'::regclass);


--
-- Name: customer_call_trunks id; Type: DEFAULT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_call_trunks ALTER COLUMN id SET DEFAULT nextval('public.customer_call_trunks_id_seq'::regclass);


--
-- Name: customer_modules id; Type: DEFAULT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_modules ALTER COLUMN id SET DEFAULT nextval('public.customer_modules_id_seq'::regclass);


--
-- Name: customers id; Type: DEFAULT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customers ALTER COLUMN id SET DEFAULT nextval('public.customers_id_seq'::regclass);


--
-- Name: encrypted_secrets id; Type: DEFAULT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.encrypted_secrets ALTER COLUMN id SET DEFAULT nextval('public.encrypted_secrets_id_seq'::regclass);


--
-- Name: modules id; Type: DEFAULT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.modules ALTER COLUMN id SET DEFAULT nextval('public.modules_id_seq'::regclass);


--
-- Name: cdr_import_batches cdr_import_batches_file_hash_key; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.cdr_import_batches
    ADD CONSTRAINT cdr_import_batches_file_hash_key UNIQUE (file_hash);


--
-- Name: cdr_import_batches cdr_import_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.cdr_import_batches
    ADD CONSTRAINT cdr_import_batches_pkey PRIMARY KEY (id);


--
-- Name: cdr_import_rejects cdr_import_rejects_pkey; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.cdr_import_rejects
    ADD CONSTRAINT cdr_import_rejects_pkey PRIMARY KEY (id);


--
-- Name: cdr_provider_calls cdr_provider_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.cdr_provider_calls
    ADD CONSTRAINT cdr_provider_calls_pkey PRIMARY KEY (id);


--
-- Name: customer_3cx_pbx customer_3cx_pbx_customer_id_base_url_key; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_3cx_pbx
    ADD CONSTRAINT customer_3cx_pbx_customer_id_base_url_key UNIQUE (customer_id, base_url);


--
-- Name: customer_3cx_pbx customer_3cx_pbx_pkey; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_3cx_pbx
    ADD CONSTRAINT customer_3cx_pbx_pkey PRIMARY KEY (id);


--
-- Name: customer_call_trunks customer_call_trunks_account_id_key; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_call_trunks
    ADD CONSTRAINT customer_call_trunks_account_id_key UNIQUE (account_id);


--
-- Name: customer_call_trunks customer_call_trunks_customer_id_account_id_key; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_call_trunks
    ADD CONSTRAINT customer_call_trunks_customer_id_account_id_key UNIQUE (customer_id, account_id);


--
-- Name: customer_call_trunks customer_call_trunks_pkey; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_call_trunks
    ADD CONSTRAINT customer_call_trunks_pkey PRIMARY KEY (id);


--
-- Name: customer_modules customer_modules_customer_id_module_id_key; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_modules
    ADD CONSTRAINT customer_modules_customer_id_module_id_key UNIQUE (customer_id, module_id);


--
-- Name: customer_modules customer_modules_pkey; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_modules
    ADD CONSTRAINT customer_modules_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: customers customers_slug_key; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_slug_key UNIQUE (slug);


--
-- Name: encrypted_secrets encrypted_secrets_customer_id_module_id_secret_name_key; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.encrypted_secrets
    ADD CONSTRAINT encrypted_secrets_customer_id_module_id_secret_name_key UNIQUE (customer_id, module_id, secret_name);


--
-- Name: encrypted_secrets encrypted_secrets_pkey; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.encrypted_secrets
    ADD CONSTRAINT encrypted_secrets_pkey PRIMARY KEY (id);


--
-- Name: modules modules_module_key_key; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_module_key_key UNIQUE (module_key);


--
-- Name: modules modules_pkey; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_pkey PRIMARY KEY (id);


--
-- Name: pbx_3cx pbx_3cx_base_url_key; Type: CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.pbx_3cx
    ADD CONSTRAINT pbx_3cx_base_url_key UNIQUE (base_url);


--
-- Name: customers_halo_alias_unique_ci; Type: INDEX; Schema: public; Owner: secrets_admin
--

CREATE UNIQUE INDEX customers_halo_alias_unique_ci ON public.customers USING btree (lower(halo_alias));


--
-- Name: idx_cdr_provider_calls_account_id; Type: INDEX; Schema: public; Owner: secrets_admin
--

CREATE INDEX idx_cdr_provider_calls_account_id ON public.cdr_provider_calls USING btree (account_id);


--
-- Name: idx_cdr_provider_calls_connect_time; Type: INDEX; Schema: public; Owner: secrets_admin
--

CREATE INDEX idx_cdr_provider_calls_connect_time ON public.cdr_provider_calls USING btree (connect_time);


--
-- Name: idx_customer_call_trunks_customer; Type: INDEX; Schema: public; Owner: secrets_admin
--

CREATE INDEX idx_customer_call_trunks_customer ON public.customer_call_trunks USING btree (customer_id);


--
-- Name: pbx_3cx_base_url_canon_uniq; Type: INDEX; Schema: public; Owner: secrets_admin
--

CREATE UNIQUE INDEX pbx_3cx_base_url_canon_uniq ON public.pbx_3cx USING btree (lower(regexp_replace(TRIM(BOTH FROM base_url), '/+$'::text, ''::text)));


--
-- Name: cdr_import_rejects cdr_import_rejects_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.cdr_import_rejects
    ADD CONSTRAINT cdr_import_rejects_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.cdr_import_batches(id);


--
-- Name: cdr_provider_calls cdr_provider_calls_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.cdr_provider_calls
    ADD CONSTRAINT cdr_provider_calls_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.cdr_import_batches(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;


--
-- Name: customer_3cx_pbx customer_3cx_pbx_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_3cx_pbx
    ADD CONSTRAINT customer_3cx_pbx_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: customer_call_trunks customer_call_trunks_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_call_trunks
    ADD CONSTRAINT customer_call_trunks_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: customer_modules customer_modules_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_modules
    ADD CONSTRAINT customer_modules_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: customer_modules customer_modules_module_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.customer_modules
    ADD CONSTRAINT customer_modules_module_id_fkey FOREIGN KEY (module_id) REFERENCES public.modules(id) ON DELETE CASCADE;


--
-- Name: encrypted_secrets encrypted_secrets_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.encrypted_secrets
    ADD CONSTRAINT encrypted_secrets_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: encrypted_secrets encrypted_secrets_module_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.encrypted_secrets
    ADD CONSTRAINT encrypted_secrets_module_id_fkey FOREIGN KEY (module_id) REFERENCES public.modules(id) ON DELETE CASCADE;


--
-- Name: pbx_3cx pbx_3cx_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: secrets_admin
--

ALTER TABLE ONLY public.pbx_3cx
    ADD CONSTRAINT pbx_3cx_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO secrets_portal;


--
-- Name: FUNCTION fn_upsert_pbx_3cx(p_customer_id bigint, p_base_url text, p_verify_tls boolean, p_username text, p_password text, p_mfa text, p_master_key text); Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT ALL ON FUNCTION public.fn_upsert_pbx_3cx(p_customer_id bigint, p_base_url text, p_verify_tls boolean, p_username text, p_password text, p_mfa text, p_master_key text) TO secrets_writer;


--
-- Name: TABLE cdr_import_batches; Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT SELECT,INSERT ON TABLE public.cdr_import_batches TO secrets_writer;


--
-- Name: SEQUENCE cdr_import_batches_id_seq; Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.cdr_import_batches_id_seq TO secrets_writer;


--
-- Name: TABLE cdr_import_rejects; Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT SELECT,INSERT ON TABLE public.cdr_import_rejects TO secrets_writer;


--
-- Name: SEQUENCE cdr_import_rejects_id_seq; Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.cdr_import_rejects_id_seq TO secrets_writer;


--
-- Name: TABLE cdr_provider_calls; Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT SELECT,INSERT ON TABLE public.cdr_provider_calls TO secrets_writer;


--
-- Name: SEQUENCE cdr_provider_calls_id_seq; Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT SELECT,USAGE ON SEQUENCE public.cdr_provider_calls_id_seq TO secrets_writer;


--
-- Name: TABLE customer_call_trunks; Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT SELECT ON TABLE public.customer_call_trunks TO secrets_writer;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT SELECT ON TABLE public.customers TO secrets_writer;
GRANT SELECT ON TABLE public.customers TO secrets_portal;


--
-- Name: TABLE pbx_3cx; Type: ACL; Schema: public; Owner: secrets_admin
--

GRANT SELECT ON TABLE public.pbx_3cx TO secrets_writer;
GRANT SELECT,INSERT,UPDATE ON TABLE public.pbx_3cx TO secrets_portal;


--
-- PostgreSQL database dump complete
--

\unrestrict AQV1JocMmV6PB4AuEnek9Nee008508OWl4pnQukPATStn7Q0HBpg9rj2rzzxPfe

