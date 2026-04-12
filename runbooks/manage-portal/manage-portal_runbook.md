<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# Manage Portal — Authoritative Runbook (ZaheZone)

---


**Component:** manage-portal  
**Classification:** INFRA  
**Authoritative runtime location:** `/opt/manage-portal`  
**Last validated:** 2026-04-12  

---

## 1) Purpose

- TODO

---

## 2) Scope / Responsibilities

### Does
- TODO

### Does NOT
- TODO

---

## 3) Runtime Architecture

- Runtime type: (systemd / docker / compose)
- Entrypoint:
- Ports:
- Reverse proxy / auth:

---

## 4) Dependencies

- Upstream dependencies:
- Downstream dependencies:

---

## 5) Data / Storage

- Reads:
- Writes:
- Secrets:

---

## 6) Operational Lifecycle

### Start
- TODO

### Stop
- TODO

### Restart
- TODO

### Upgrade
- TODO

### Rollback
- TODO

---

## 7) Validation Checklist

- [ ] Service is running
- [ ] Health checks pass
- [ ] Logs show expected activity

---

## 8) Failure Modes & Recovery

- TODO

---

## 9) Change Log

- TODO

---

## Appendix: Legacy content


**Component:** Manage Portal  
**Classification:** CORE  
**Primary goal:** Provide the authoritative operator/admin interface so the platform’s runtime behavior is **predictable**, **auditable**, and **recoverable**.

> This runbook intentionally distinguishes between what is **confirmed** (grounded in current artifacts) and what is **VERIFY ON SERVER** (must be confirmed from the live deployment).

---

## 1) Purpose (Why this exists)

Manage Portal is the **system-of-record admin UI** for the monitoring platform. It exists so operators can:

- Maintain PBX configuration (enabled state, base URL, display name)
- Maintain 3CX management credential settings (base URL + TLS verify + username/password/MFA fields)
- Manage PBX maintenance windows (start now, schedule, stop early)
- Provide onboarding guardrails to prevent configuration drift that causes incidents (e.g., base_url mismatch between DBs)

**Non-goals**
- Does **not** poll PBXs (collector does)
- Does **not** compute rollups (metrics DB pipeline does)
- Does **not** render dashboards (Grafana does)

---

## 2) Confirmed UI capabilities (Grounded)

The following capabilities are confirmed from the portal templates currently present.

### 2.1 PBX List (3CX)
Template: `admin_pbx3cx_list.html`

Confirmed elements:
- Displays PBX rows with: ID, Display Name, Enabled, Base URL, Verify TLS, credential presence flags, maintenance status, maintenance until, actions (Edit/Maintenance). 
- Variant list view also shows health label mapping (OK/WARN/STALE/MAINT/UNKNOWN) and last polled age in seconds.

### 2.2 PBX Edit (3CX)
Template: `admin_pbx3cx_edit.html`

Confirmed fields:
- Display Name
- Enabled true/false
- Management Base URL
- Verify TLS true/false
- Username (blank=keep)
- Password (blank=keep)
- MFA / OTP (optional)

### 2.3 PBX Maintenance
Template: `admin_pbx3cx_maintenance.html`

Confirmed actions/sections:
- Shows PBX enabled + maintenance status + until + reason
- Buttons for: Start Now (≤4h), Start Schedule (≤12h), Stop Early
- Shows recent windows list

---

## 3) Data model / contracts (Critical)

### 3.1 Eligibility gates (what determines whether a PBX is polled)
Polling eligibility requires BOTH:

1) **Metrics DB:** `pbx_instances.enabled = true`
2) **Secrets DB:** `pbx_3cx.polling_enabled = true`

**Join rule:** The collector joins Secrets→Metrics by `base_url` (canonicalization matters). A mismatch (case, scheme, trailing slash, alternate hostnames) will silently exclude polling.

### 3.2 Maintenance mode contract
Maintenance mode is **window-based** (DB evaluates whether an active window exists). The portal should insert/update maintenance windows so they:
- satisfy `end_ts > start_ts`
- do not overlap per PBX (DB exclusion constraint)

### 3.3 Guardrails to prevent repeat incidents (recommended)
The platform recommendations explicitly call out:
- validate base_url (https://, no trailing slash, uniqueness)
- optional “Test Connection” on save
- show collector last run / last poll success per PBX

---

## 4) Runtime architecture (VERIFY ON SERVER)

> The following must be verified against the live deployment (container/systemd, ports, auth proxy chain).

### 4.1 How it is started
Run on host:

```bash
# find container
sudo docker ps | grep -i manage
sudo docker ps | grep -i portal

# find systemd (if used)
sudo systemctl list-unit-files | grep -i manage
sudo systemctl list-units --type=service | grep -i manage
```

Record the result here:
- Deployment type: **Docker / systemd / compose** (circle one)
- Unit name (if systemd): `____________________`
- Container name (if docker): `____________________`

### 4.2 How it is authenticated
You have oauth2-proxy binaries present under `/opt` (multiple versions). Confirm the active auth chain:

```bash
# nginx / proxy
sudo ss -lntp | egrep ':80|:443|:4180|:8080'

# running oauth2-proxy?
ps aux | grep -i oauth2-proxy | grep -v grep
sudo docker ps | grep -i oauth
```

Record:
- auth gateway component: **oauth2-proxy / other**
- active oauth2-proxy version: `____________________`

---

## 5) Operational lifecycle (how to run it)

### 5.1 Start / Stop / Restart (VERIFY exact method)
If systemd:

```bash
sudo systemctl restart manage-portal.service
sudo journalctl -u manage-portal.service -f --no-pager
```

If docker (container name example):

```bash
sudo docker restart manage-portal
sudo docker logs -f manage-portal
```

### 5.2 Upgrade
Minimum safe upgrade path:

1) Ensure GitHub repo is up to date (commit/push)
2) Build new image (if docker)
3) Restart service
4) Validate: PBX list loads, edit saves, maintenance start/stop works

### 5.3 Rollback
1) Checkout prior tag/commit
2) Rebuild prior image
3) Restart
4) Validate same checks

---

## 6) Troubleshooting (fast, deterministic)

### 6.1 PBX not polling after enabling
Checks:

- Metrics DB: PBX is enabled (`pbx_instances.enabled=true`)
- Secrets DB: polling enabled (`pbx_3cx.polling_enabled=true`)
- base_url matches canonically across DBs (case + trailing slash + hostname)

Common failure seen previously:
- duplicate secrets entries with different base_url values where the enabled entry did not match the metrics DB base_url.

### 6.2 Maintenance not reflected
Checks:

- active window exists (start<=now<=end)
- no overlaps (DB constraint)
- portal is writing correct pbx_id

### 6.3 PBX list health/last-polled not updating
Template supports health label + last polled age. If blank:
- portal query feeding the list is missing joins to metrics views/tables

---

## 7) Security requirements

- Never commit `.env` files, master keys, or secrets.
- Credentials must remain encrypted at rest (Secrets DB).
- UI must not print secrets in templates or logs.

---

## 8) Documentation contract (prevents future “mystery module” issues)

For Manage Portal to remain auditable:

- Any new admin action must be added to this runbook before production use.
- Any changes affecting PBX enable/poll gating, base_url handling, or maintenance windows must be documented here.

---

## 9) Server validation checklist (to confirm this runbook matches reality)

Run and record results:

1) **Routes exist**: confirm the portal serves PBX list/edit/maintenance pages in browser.
2) **DB writes**: toggling enabled/maintenance changes DB as expected.
3) **Collector observes changes**: enable/disable polling affects eligible PBX count next cycle.
4) **Auth chain**: confirm the active oauth2-proxy version/process and where it is configured.

---

## 10) GitHub action (mandatory)

When you start or complete a module artifact (including documentation), commit + push:

```bash
cd /opt/manage-portal
mkdir -p runbooks
cp /path/to/this/file runbooks/manage-portal_runbook.md

git add -A
git commit -m "Add authoritative Manage Portal runbook"

git push
```

If the repo does not exist yet, create and push in one step:

```bash
gh repo create ScottHolzberger/manage-portal --private --source=. --push
```
