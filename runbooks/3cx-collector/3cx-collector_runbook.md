# 3CX Collector — Authoritative Runbook (ZaheZone)

Generated/maintained by: ZaheZone Platform Ops  
Scope: Production runtime + rebuild/upgrade guidance  
Last reviewed: _UPDATE DATE_

---

## 1) Purpose (why it exists)

- Poll each configured 3CX instance (PBX) using token auth + XAPI.
- Persist operational telemetry to the Metrics DB for dashboards/alerts.
- Persist a heartbeat used by “Up/Down” and “Last Seen” views.

**Non-goals**
- Not an admin/config system of record (that is the portal/admin DB + UI).
- Not a UI service.
- Not a “repair” tool for PBX configuration or licensing.

---

## 2) Runtime Architecture (what runs where)

### 2.1 Deployed process (container)
- Runs as a Docker container executing Python with `collector.py`. [1](https://zahe.sharepoint.com/sites/SOP/Shared%20Documents/3CX%20Monitoring%20&%20Management%20Portal/runbook/archive/collector-segmentation-2026-04/phase1/phase1C_collector_inventory/docker_inspect_3cx-collector.json?web=1)
  - Example container args show `python -u collector.py`. [1](https://zahe.sharepoint.com/sites/SOP/Shared%20Documents/3CX%20Monitoring%20&%20Management%20Portal/runbook/archive/collector-segmentation-2026-04/phase1/phase1C_collector_inventory/docker_inspect_3cx-collector.json?web=1)

### 2.2 Service lifecycle
- Managed by systemd on the host (recommended), which ensures:
  - Auto-start on reboot
  - Restart on failure
  - Centralized logs via `journalctl`

> NOTE: systemd unit should be stored in repo and installed to `/etc/systemd/system/`.

### 2.3 Networks / connectivity
- Requires egress to each PBX management base URL (HTTPS).
- Requires connectivity to:
  - Secrets DB (credentials + polling flags)
  - Metrics DB (metrics + status + views)

---

## 3) Data dependencies (databases involved)

Collector uses **two separate databases**:

### 3.1 Secrets DB (monitor_secrets)
**Role**
- Stores encrypted credentials for 3CX instances.
- Stores polling enable/disable flag.
- Collector reads “pollable” PBXs from here.

**Primary table**
- `pbx_3cx` (encrypted fields; polling_enabled flag)

**Operational note**
- The Secrets DB is the authority for “can collector authenticate to PBX?”

### 3.2 Metrics DB (monitor_metrics)
**Role**
- Stores time-series metrics (append-only), latest values, rollups and heartbeat.
- Drives Grafana dashboards, including “Up/Down / Last Seen”.

**Primary tables**
- `metric_points` (append-only)
- `pbx_metric_latest` (latest JSON/num values)
- `pbx_status_latest` (heartbeat status/last seen)
- `pbx_instances` (PBX registry / enabled flag)
- `pbx_maintenance_windows` (maintenance windows used by `v_pbx_current_status`)

**View used by Grafana for status**
- `v_pbx_current_status` joins `pbx_instances` to `pbx_status_latest` and evaluates whether a PBX is in an active maintenance window. [4](https://zahe.sharepoint.com/sites/SOP/Shared%20Documents/3CX%20Monitoring%20&%20Management%20Portal/20260405/backups/pbx-admin-ui-20260404T133546Z/admin_pbx3cx_maintenance.html?web=1)

---

## 4) Eligibility rules (when a PBX is polled)

A PBX is eligible only when BOTH are true:

- Metrics DB: `pbx_instances.enabled = true`
- Secrets DB: `pbx_3cx.polling_enabled = true`

**Join key**
- PBX matching across DBs is based on `base_url`.
- Canonical form MUST be consistent (lowercase + no trailing slash).
  - Mismatches cause silent skip at runtime (most common source of “why isn’t it polling?”).

---

## 5) Collector design decisions (why it is built this way)

### 5.1 Hot reload poll set (no restart required)
- Each poll cycle re-queries Secrets DB + Metrics DB to rebuild the eligible PBX set.
- Benefits:
  - Changing polling_enabled / enabled takes effect next cycle.
  - Prevents “restart required for config drift”.

### 5.2 Token caching
- Token cached per PBX for a TTL.
- Intended effect: reduce time spent logging in each cycle (login is the dominant latency).

### 5.3 Resilience: per-PBX isolation
- A single failing PBX must not block others.
- Each PBX poll is isolated and errors are logged per PBX.
- This aligns with the “collector resilience” recommendation: isolate failures and implement per-PBX backoff. [3](https://outlook.office365.com/owa/?ItemID=AAMkADhlMTM2M2M5LTMwMDAtNDhmMy05NWEzLTdiNmE3M2FhZjc4MQBGAAAAAADb8e2aAMxXSpYvmbR2C5nJBwDMTeUeLbukSoYFIhN4KOryAAAAAAEMAADMTeUeLbukSoYFIhN4KOryAAtCsYymAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

### 5.4 Per-PBX backoff / circuit breaker
- On repeated failure, PBX enters backoff to avoid thrashing and excessive retries.
- Backoff should be capped.

### 5.5 TLS verification handling
- PBXs may be configured with verify TLS ON or OFF.
- Shared HTTP client patterns must account for mixed TLS verify states.
  - Common implementation approach: two shared clients (verify=True and verify=False) and select per PBX.

---

## 6) Metrics contract (what the collector writes)

### 6.1 Time-series (append-only): `metric_points`
- `active_calls` (numeric)
- `licensed_calls` (numeric)
- `pbx_up` (numeric; 1 on success)

**Important**
- `metric_points` is append-only; mutations are blocked (no deletes/updates).
- Any fixes must be done by writing correct future rows, not by deleting.

### 6.2 Latest-only: `pbx_metric_latest`
Values stored as either:
- `value_json` (strings/structured)
- `value_num` (numeric)

**Expected latest keys**
- `3cx_version` (value_json)
- `fqdn` (value_json)
- `ipv4` (value_json)
- `license_key` (value_json)
- `product_code` (value_json)
- `maintenance_expires` (value_json)
- `last_backup` (value_num epoch seconds)

**Critical**
- `last_backup` MUST be epoch seconds in `value_num` because Grafana uses `to_timestamp(value_num)`.

### 6.3 Heartbeat: `pbx_status_latest` (drives “Last Seen”)
On successful poll:
- Upsert `pbx_status_latest`:
  - `status='up'`
  - `last_seen_ts=NOW()`
  - `last_change_ts` only changes when status changes

This is required because `v_pbx_current_status` reads `pbx_status_latest` to determine “Up/Down” and “Last Seen”. [4](https://zahe.sharepoint.com/sites/SOP/Shared%20Documents/3CX%20Monitoring%20&%20Management%20Portal/20260405/backups/pbx-admin-ui-20260404T133546Z/admin_pbx3cx_maintenance.html?web=1)

---

## 7) Maintenance Mode (how it’s determined)
Maintenance mode is **DB-window based**, not “status” based:

- Active window exists when:
  - `start_ts <= now()` and `end_ts >= now()`

The Admin maintenance page reflects this model and supports starting/stopping maintenance windows. [4](https://zahe.sharepoint.com/sites/SOP/Shared%20Documents/3CX%20Monitoring%20&%20Management%20Portal/20260405/backups/pbx-admin-ui-20260404T133546Z/admin_pbx3cx_maintenance.html?web=1)

---

## 8) Operational lifecycle

### 8.1 Build
- Build a new image from `/opt/3cx-collector` (Dockerfile + collector.py).

### 8.2 Deploy
- If systemd-managed: restart the systemd service.
- If manually run: stop/remove old container, run new container.

### 8.3 Rollback
- Rebuild image from prior commit/tag.
- Restart service.
- Confirm poll cycle resumes.

---

## 9) Validation / health checks

### 9.1 Collector running
- systemd status: `systemctl status 3cx-collector.service`
- logs: `journalctl -u 3cx-collector.service -f`

### 9.2 Metrics DB writes
- Confirm recent `metric_points` rows for `active_calls`.

### 9.3 Latest fields
- Confirm `pbx_metric_latest` contains expected metrics (especially `last_backup` as epoch).

### 9.4 Heartbeat correctness
- Confirm `pbx_status_latest.last_seen_ts` advances per PBX.

---

## 10) Troubleshooting playbook

### 10.1 PBX not polling (most common)
- Check Metrics DB: `pbx_instances.enabled`
- Check Secrets DB: `pbx_3cx.polling_enabled`
- Compare base_url values in both DBs (canonicalization)
- Check collector log for “eligible PBX count” and whether PBX appears in list

### 10.2 Status shows UNKNOWN / Last Seen not updating
- Confirm collector writes heartbeat to `pbx_status_latest`
- Confirm view `v_pbx_current_status` joins to `pbx_status_latest` (it does). [4](https://zahe.sharepoint.com/sites/SOP/Shared%20Documents/3CX%20Monitoring%20&%20Management%20Portal/20260405/backups/pbx-admin-ui-20260404T133546Z/admin_pbx3cx_maintenance.html?web=1)

### 10.3 Backup health incorrect
- Confirm `last_backup` uses `value_num` epoch seconds
- Confirm `LastBackupDateTime` exists in PBX system status payload and is converted before write

### 10.4 Login slow
- Expected: login dominates time; systemstatus and DB writes are fast.
- Ensure token caching is enabled; avoid logging in every cycle if token is valid.

---

## 11) Security requirements

- `.env` files must not be committed
- Never store plaintext credentials in repo
- Secrets DB must store encrypted secrets only
- Any “audit dump” files must be redacted before sharing (see manifest). [2](https://zahe-my.sharepoint.com/personal/scott_zahezone_com_au/Documents/Microsoft%20Copilot%20Chat%20Files/MANIFEST.txt?web=1)

---

## 12) Repo hygiene (what must be in GitHub)

Required:
- `collector.py`
- `Dockerfile`
- `config.yaml.example`
- `systemd/3cx-collector.service`
- `runbooks/3cx-collector_runbook.md`

Not allowed:
- `.env`
- backups
- docker inspect dumps (unless explicitly sanitized/redacted)

---

## 13) Roadmap / recommended improvements (aligned to platform notes)
- Continue strengthening per-PBX isolation and backoff patterns. [3](https://outlook.office365.com/owa/?ItemID=AAMkADhlMTM2M2M5LTMwMDAtNDhmMy05NWEzLTdiNmE3M2FhZjc4MQBGAAAAAADb8e2aAMxXSpYvmbR2C5nJBwDMTeUeLbukSoYFIhN4KOryAAAAAAEMAADMTeUeLbukSoYFIhN4KOryAAtCsYymAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)
- Persist per-PBX last success/error summary into a “latest” record for easier ops triage. [3](https://outlook.office365.com/owa/?ItemID=AAMkADhlMTM2M2M5LTMwMDAtNDhmMy05NWEzLTdiNmE3M2FhZjc4MQBGAAAAAADb8e2aAMxXSpYvmbR2C5nJBwDMTeUeLbukSoYFIhN4KOryAAAAAAEMAADMTeUeLbukSoYFIhN4KOryAAtCsYymAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)
- Add input validation for base_url uniqueness at the portal layer to prevent duplicates. [3](https://outlook.office365.com/owa/?ItemID=AAMkADhlMTM2M2M5LTMwMDAtNDhmMy05NWEzLTdiNmE3M2FhZjc4MQBGAAAAAADb8e2aAMxXSpYvmbR2C5nJBwDMTeUeLbukSoYFIhN4KOryAAAAAAEMAADMTeUeLbukSoYFIhN4KOryAAtCsYymAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

asd