<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# Manage Portal — Authoritative Runbook (ZaheZone)

- **Component:** manage-portal
- **Classification:** INFRA
- **Authoritative runtime location:** `/opt/manage-portal`
- **Last validated:** 2026-04-13

## 1) Purpose
- Provide the **operator/admin web UI** for managing configuration that drives the monitoring + billing platform.
- Make runtime behavior **predictable**, **auditable**, and **recoverable** by centralizing CRUD operations behind a controlled UI.

## 2) Scope / Responsibilities

### Does
- PBX administration (3CX): list, create, edit, and maintenance windows.
- Customer administration: list, add, edit customers used by monitoring/billing mappings.
- Trunk administration: list, add, edit trunks and link trunks to customers and PBX systems.
- Enforces guardrails on critical fields (e.g., canonical URL formats) to prevent silent polling exclusions.

### Does NOT
- Poll PBXs (collector does).
- Render dashboards (Grafana does).
- Store or display plaintext secrets.

## 3) Runtime Architecture (VERIFY ON SERVER)
> This section must be verified from the live host because deployment method can vary.

- **Runtime type:** VERIFY (systemd / docker / compose)
- **Entrypoint:** VERIFY
- **Ports:** VERIFY
- **Reverse proxy / auth:** VERIFY (expected oauth2-proxy or equivalent)

### How to verify on the server
- Identify runtime:
  - `sudo docker ps | egrep -i 'manage|portal'`
  - `sudo systemctl list-units --type=service | egrep -i 'manage|portal'`
- Identify listeners/auth chain:
  - `sudo ss -lntp | egrep ':80|:443|:4180|:8080'`
  - `ps aux | grep -i oauth2-proxy | grep -v grep`

## 4) Dependencies

### Upstream
- PostgreSQL **metrics/config** database (contains PBX/customer/trunk runtime tables and views).
- PostgreSQL **secrets** database (contains encrypted secrets / PBX auth material).

### Downstream
- 3cx-collector (consumes PBX eligibility & secrets; joins by canonical base_url).
- Alerting pipeline / Grafana reads derived metrics & views.

## 5) Data / Storage

### 5.1 Key tables/views (observed in schema exports)

**PBX**
- `public.pbx_instances` (PBX id, customer_slug, name, base_url, enabled) — metrics/config DB.
- `public.pbx_maintenance_windows` (maintenance windows) — metrics/config DB.
- `public.v_admin_pbx_overview` (PBX list view incl. health + last polled) — metrics/config DB.

**Customers / Trunks (runtime/billing layer)**
- `public.customers` (customer_slug, display_name, status, billing_ref, notes)
- `public.trunks` (trunk_id, customer_slug, pbx_id, trunk_type, status, concurrency_cap, notes)

**Customers / Trunks (manage configuration layer)**
- `manage_cfg.customers` (halo_customer_id, customer_slug, display_name, status, billing_ref, notes)
- `manage_cfg.trunk_modules` (trunk_id, provider, pbx_module_id, monitoring_enabled, concurrency_cap, notes)
- `manage_cfg.pbx_modules` (pbx_fqdn, management_url, verify_tls, polling_enabled, etc)
- `public.v_manage_cfg_customers`, `public.v_manage_cfg_trunk`, `public.v_manage_cfg_pbx` (read views)

> NOTE: Decide which layer is *authoritative* for UI writes (public.* vs manage_cfg.*). If uncertain, treat **manage_cfg** as the source-of-truth for module configuration and **public** as the runtime/billing layer.

### 5.2 Eligibility gates (polling)
Polling eligibility requires BOTH:
- Metrics/config DB: `public.pbx_instances.enabled = true`
- Secrets DB: `pbx_3cx.polling_enabled = true`

**Join rule:** collector joins Secrets→Metrics by canonical `base_url`. Canonicalization (scheme/case/trailing slash/hostname) must match exactly or the PBX will be silently excluded.

### 5.3 Security requirements
- Never commit `.env` files, master keys, or secrets.
- Credentials must remain encrypted at rest.
- UI must not render secrets in templates or logs.

## 6) Operator UI Routes (current + planned)

### 6.1 Current (confirmed by templates)
- `GET /admin/pbx` — PBX list
- `GET /admin/pbx/new` — PBX create form
- `GET /admin/pbx/{id}` — PBX edit form
- `GET /admin/pbx/{id}/maintenance` — maintenance page
- `POST /admin/pbx/new` — create PBX
- `POST /admin/pbx/{id}` — update PBX
- `POST /admin/pbx/{id}/maintenance/*` — maintenance actions

### 6.2 Planned (requested work)
- `GET /admin` — landing page (navigation tiles)
- `GET /admin/customers` — customers list
- `GET/POST /admin/customers/new` — add customer
- `GET/POST /admin/customers/{customer_slug}` — edit customer
- `GET /admin/trunks` — trunks list
- `GET/POST /admin/trunks/new` — add trunk
- `GET/POST /admin/trunks/{trunk_id}` — edit trunk

## 7) Operational Lifecycle

### Start / Stop / Restart (VERIFY exact method)
If systemd:
- `sudo systemctl restart manage-portal.service`
- `sudo journalctl -u manage-portal.service -f --no-pager`

If docker:
- `sudo docker restart manage-portal`
- `sudo docker logs -f manage-portal`

### Upgrade
- Commit + push changes to GitHub.
- Build/deploy (docker image or systemd artifact) as per runtime method.
- Validate via checklist below.

### Rollback
- Checkout prior tag/commit.
- Rebuild/redeploy prior artifact.
- Validate via checklist below.

## 8) Validation Checklist
- `GET /admin` loads and shows navigation.
- `GET /admin/pbx` loads and shows PBX rows.
- Create PBX (`/admin/pbx/new`) succeeds and PBX appears in list.
- Edit PBX (`/admin/pbx/{id}`) saves without error.
- Maintenance actions update `public.pbx_maintenance_windows` and reflect on list.
- Customer CRUD works (list/add/edit).
- Trunk CRUD works (list/add/edit) and trunk-to-customer / trunk-to-pbx links persist.
- No secrets are displayed or logged.

## 9) Failure Modes & Recovery

### PBX not polling after enabling
- Confirm `public.pbx_instances.enabled = true`.
- Confirm Secrets DB `pbx_3cx.polling_enabled = true`.
- Confirm `base_url` canonicalization matches across DBs.

### Maintenance not reflected
- Confirm active window exists (`start_ts <= now <= end_ts`).
- Confirm no overlaps (DB constraint).
- Confirm portal writes correct `pbx_id`.

### PBX list health/last-polled not updating
- `public.v_admin_pbx_overview` is expected to supply `health_label` and `last_polled`.
- If blanks: list query may be missing the join/view.

## 10) Documentation Contract
- Any new admin action must be added to this runbook **before production use**.
- Any changes affecting PBX enable/poll gating, `base_url` handling, maintenance windows, customers, or trunks must be documented here.

## 11) GitHub action (mandatory)
When you start or complete a module artifact (including documentation), commit + push:

```bash
cd /opt/manage-portal
mkdir -p runbooks
cp /opt/Documentation/runbooks/manage-portal/manage-portal_runbook.md runbooks/manage-portal_runbook.md
git add -A
git commit -m "Update Manage Portal runbook"
git push
```

If the repo does not exist yet, create and push in one step:

```bash
gh repo create ScottHolzberger/manage-portal --private --source=. --push
```
