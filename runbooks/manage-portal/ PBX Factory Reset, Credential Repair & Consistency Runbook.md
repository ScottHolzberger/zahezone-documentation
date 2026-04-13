
PBX Factory Reset, Credential Repair & Consistency Runbook
Owner: ZaheZone Operations
Scope: 3CX PBX lifecycle management (add, reset, credential repair)
Datastores:

monitor_metrics (PBX systems, instances, metrics)
monitor_secrets (encrypted credentials)
This runbook documents the authoritative, production‑safe process used to:

fully remove incorrectly created PBXs
repair credential save failures
re‑add PBXs cleanly
verify database consistency against a known‑good reference PBX


1. Background / Problem Summary
During onboarding of a PBX (zztester.3cx.com.au), the following issues were encountered:

PBXs created incorrectly could not be reused
Test‑only PBXs polluted the system and blocked testing
Credential save failed with AmbiguousParameterError
Full deletion was blocked due to TimescaleDB FK triggers
The root causes were:

PostgreSQL running inside Docker with non‑default roles
TimescaleDB trigger enforcement on metric_points
asyncpg NULL parameter typing in CASE expressions
Inconsistent PBX metadata (display name vs instance name)
This runbook records the final resolved state and exact corrective actions.


2. Architecture Overview (Authoritative)
monitor_metrics

Table	Purpose
pbx_systems	Canonical PBX definition (FQDN, API URL, enablement)
pbx_instances	Runtime / polling identity (1:1 with pbx_systems.id)
metric_points	Timescale hypertable for historical metrics
pbx_metric_latest	Latest metric snapshot per PBX
pbx_status_latest	Last seen / health status

monitor_secrets

Table	Purpose
pbx_3cx	Encrypted credentials and polling configuration

Critical design rules:

pbx_systems.id == pbx_instances.id (mandatory)
pbx_systems.api_base_url == pbx_instances.base_url (canonical URL)
Enabled PBXs must have secrets_ref populated
TimescaleDB enforces FK integrity via triggers


3. Docker / Database Access (Required)
PostgreSQL runs inside Docker, not on the host.
Discover credentials
docker inspect monitor-metrics-db \
  --format='{{range .Config.Env}}{{println .}}{{end}}' | grep POSTGRES
Expected output:
POSTGRES_DB=monitor_metrics
POSTGRES_USER=metrics_writer
POSTGRES_PASSWORD=CHANGE_ME_metrics


Connect to the databases
docker exec -it monitor-metrics-db bash
psql -h localhost -U metrics_writer monitor_metrics
psql -h localhost -U metrics_writer monitor_secrets


Verify superuser:
SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user;




4. Full PBX Removal (Factory Reset)
Used when a PBX must be completely removed to allow clean re‑add.
4.1 Enable Timescale maintenance mode (session‑only)
SET session_replication_role = replica;


4.2 Remove PBX rows
BEGIN;

DELETE FROM public.pbx_instances
WHERE base_url IN (
  'https://zztester.3cx.com.au',
  'https://tester.3cx.com.au',
  'https://thing.3cx.com.au'
);

DELETE FROM public.pbx_systems
WHERE pbx_fqdn IN (
  'zztester.3cx.com.au',
  'tester.3cx.com.au',
  'thing.3cx.com.au'
);

COMMIT;


4.3 Restore normal DB behavior
SET session_replication_role = DEFAULT;


4.4 Secrets cleanup (if required)
DELETE FROM public.pbx_3cx
WHERE base_url IN (
  'https://zztester.3cx.com.au',
  'https://tester.3cx.com.au',
  'https://thing.3cx.com.au'
);




5. Critical Application Fix – AmbiguousParameterError
5.1 Symptom
Saving credentials failed with:
AmbiguousParameterError: could not determine data type of parameter $4


5.2 Root cause
asyncpg cannot infer parameter types in CASE WHEN $n IS NULL expressions.
5.3 Authoritative fix (admin_pbx.py)
Before (broken):
CASE WHEN $4 IS NULL THEN NULL::bytea
     ELSE pgp_sym_encrypt($4::text, $7::text)
END


After (correct):
CASE WHEN $4::text IS NULL THEN NULL::bytea
     ELSE pgp_sym_encrypt($4::text, $7::text)
END


5.4 Final corrected SQL block
INSERT INTO public.pbx_3cx
  (base_url, verify_tls, polling_enabled,
   username_enc, password_enc, mfa_enc)
VALUES
  (
    $1::text,
    $2::boolean,
    $3::boolean,
    CASE
      WHEN $4::text IS NULL THEN NULL::bytea
      ELSE pgp_sym_encrypt($4::text, $7::text)
    END,
    CASE
      WHEN $5::text IS NULL THEN NULL::bytea
      ELSE pgp_sym_encrypt($5::text, $7::text)
    END,
    CASE
      WHEN $6::text IS NULL THEN NULL::bytea
      ELSE pgp_sym_encrypt($6::text, $7::text)
    END
  )
ON CONFLICT (base_url) DO UPDATE
SET
  verify_tls      = EXCLUDED.verify_tls,
  polling_enabled = EXCLUDED.polling_enabled,
  username_enc    = COALESCE(EXCLUDED.username_enc, public.pbx_3cx.username_enc),
  password_enc    = COALESCE(EXCLUDED.password_enc, public.pbx_3cx.password_enc),
  mfa_enc         = COALESCE(EXCLUDED.mfa_enc,      public.pbx_3cx.mfa_enc);




6. PBX Metadata Consistency Normalisation
Issue Identified

pbx_systems.display_name was missing
pbx_instances.name used FQDN instead of customer display name
Corrective SQL
BEGIN;

UPDATE public.pbx_systems
SET display_name = 'Test Customer'
WHERE pbx_fqdn = 'zztester.3cx.com.au';

UPDATE public.pbx_instances
SET name = 'Test Customer'
WHERE base_url = 'https://zztester.3cx.com.au';

COMMIT;




7. Known‑Good Consistency Check (CBH Reference)
Use a known‑good PBX (cbh.3cx.com.au) as baseline:
SELECT
  ps.pbx_fqdn,
  ps.display_name,
  pi.name,
  ps.api_base_url,
  pi.base_url,
  ps.enabled,
  ps.secrets_ref
FROM public.pbx_systems ps
JOIN public.pbx_instances pi ON pi.id = ps.id
WHERE ps.pbx_fqdn IN (
  'cbh.3cx.com.au',
  'zztester.3cx.com.au'
);


Expected alignment:

Same display_name semantics
Same URL canonicalisation model
Same enabled/secrets behavior


8. Final State (Exit Criteria)
✅ PBX can be added cleanly
✅ Test Connection passes
✅ Credentials save without 500 error
✅ PBX enabled, polling active
✅ DB state matches known‑good reference


9. Operational Guardrails (Recommended)

Never hard‑delete PBXs without session_replication_role = replica
Treat PBX reset as a privileged DB operation
Enforce typed parameters in all SQL with CASE
Keep display_name and instance.name in sync


End of authoritative runbook.
