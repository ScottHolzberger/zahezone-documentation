<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# PBX Onboarding – Manage Portal (3CX)

## Purpose
Onboard a new 3CX PBX into ZaheZone monitoring safely, ensuring credentials are stored only in the secrets database and a PBX cannot be enabled unless it is linked to secrets.

## System Boundaries (Authoritative)
- **monitor_metrics**: operational records and admin UI (PBX inventory, enabled state, secrets reference)
- **monitor_secrets**: encrypted credentials (`pbx_3cx`) and secrets-side customer identity

## Key Constraints
- `public.pbx_systems.enabled_requires_secrets_ref`: `enabled = false OR secrets_ref IS NOT NULL`
- `public.pbx_systems.pbx_systems_fqdn_not_null`: FQDN must be set and not empty

## Lifecycle
### Phase 1 — Register PBX (disabled)
1. In Admin UI: **PBX → Add PBX**
2. Enter:
   - Customer
   - PBX FQDN (must be `*.3cx.com.au`, no scheme, no trailing slash)
   - Optional display name
3. System will:
   - Set `api_base_url = https://{pbx_fqdn}`
   - Create/Upsert `pbx_instances` base URL
   - Force `enabled = false`

**Expected result:** PBX appears in `/admin/pbx` with Base URL visible, but shows Disabled.

### Phase 2 — Store credentials (secrets)
1. In Admin UI: **PBX → Credentials**
2. Enter:
   - Username
   - Password
   - MFA / OTP (optional)
   - Verify TLS (default true)
   - Polling enabled (default true)
3. System will:
   - Ensure secrets-side customer exists in `monitor_secrets.public.customers` (requires `halo_alias`)
   - Encrypt credentials using `monitor_secrets.public.encrypt(bytea, bytea, text)`
   - Upsert into `monitor_secrets.public.pbx_3cx` by `base_url`
   - Set `monitor_metrics.public.pbx_systems.secrets_ref = base_url`

### Phase 3 — Enable PBX
1. In the Credentials screen, tick **Enable PBX after saving** (default on)
2. System will set `enabled = true` only after `secrets_ref` exists.

**Expected result:** PBX shows Enabled in `/admin/pbx`.

### Phase 4 — Polling & Grafana
Once enabled and credentials exist:
- Collector polls the PBX and populates runtime/status tables.
- Grafana dashboards will begin showing the PBX after the next polling cycle.

## Troubleshooting
### Error: enabled_requires_secrets_ref
- Cause: attempting to enable PBX with `secrets_ref` missing.
- Fix: save credentials first; confirm `secrets_ref` is set.

### Base URL blank in PBX list
- Cause: `pbx_instances.base_url` missing.
- Fix: edit PBX and save, or ensure Phase 1 completed (api_base_url set).

### Secrets customer insert fails
- `monitor_secrets.public.customers.halo_alias` is NOT NULL.
- Ensure `manage_cfg.customer_halo_map` has the Halo customer ID for the PBX customer slug.

## Data Operations (DB)
### Verify PBX link state (monitor_metrics)
```sql
SELECT id, pbx_fqdn, enabled, secrets_ref
FROM public.pbx_systems
WHERE pbx_fqdn = '<fqdn>';
```

### Verify secrets PBX record exists (monitor_secrets)
```sql
SELECT customer_id, base_url, verify_tls, polling_enabled
FROM public.pbx_3cx
WHERE base_url = 'https://<fqdn>';
```
