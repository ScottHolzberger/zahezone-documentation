<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# oauth2-proxy & Authentication Chain — Authoritative Runbook (ZaheZone)

**Component:** oauth2-proxy (Authentication Gateway)  
**Classification:** INFRA (shared upstream dependency)  
**Authoritative runtime location:** `/opt/auth`  
**Last validated:** 2026-04-12

---

## 1) Purpose

oauth2-proxy provides **authentication and session enforcement** in front of internal ZaheZone admin services (e.g. Manage Portal, Monitor Portal). It exists to:

- Centralise authentication and session handling
- Keep backend services bound to localhost and unauthenticated
- Provide a clear, auditable auth boundary for all admin tooling

---

## 2) High-level authentication chain (authoritative)

```
Internet
  ↓
nginx (:80 / :443)
  ↓
oauth2-proxy (:4180)
  ↓
Backend services (localhost)
  ├─ manage-portal :8092   (CORE)
  └─ monitor-portal :8088  (LEGACY)
```

nginx is the public entry point. oauth2-proxy is the single authentication gate.

---

## 3) Runtime model (current, validated)

oauth2-proxy runs as **bare OS processes** (not Docker, not systemd-managed).

### 3.1 Binary

- **Binary:** `/usr/local/bin/oauth2-proxy`
- Binary is treated as an immutable system dependency.

### 3.2 Instances

Two oauth2-proxy instances are intentionally running:

| Instance | Runtime config | Purpose |
|--------|----------------|---------|
| Main Auth | `oauth2-proxy.toml` | Protects CORE admin services (Manage Portal) |
| Monitor Auth | `oauth2-proxy-monitor.toml` | Protects legacy Monitor Portal |

---

## 4) Authoritative filesystem layout (target state)

All oauth2-proxy–owned runtime assets must live under `/opt/auth`.

```
/opt/auth/
├── README.md
├── runbooks/
│   └── oauth2-proxy_runbook.md
├── config/
│   ├── oauth2-proxy.toml
│   └── oauth2-proxy-monitor.toml
├── archive/
│   └── deprecated-configs/
```

Rules:
- `/opt/auth/config` is the **only supported config location**
- Anything outside `/opt/auth` is unsupported
- Archived files are never referenced by nginx or startup commands

---

## 5) Current → target realignment steps (controlled, low risk)

> These steps **do not change behaviour**, only paths.

### Step 1 — Create authoritative auth root

```bash
sudo mkdir -p /opt/auth/{config,runbooks,archive}
sudo chown -R root:root /opt/auth
sudo chmod 750 /opt/auth
```

### Step 2 — Move configs into `/opt/auth`

```bash
sudo mv /etc/oauth2-proxy/oauth2-proxy.toml /opt/auth/config/
sudo mv /etc/oauth2-proxy/oauth2-proxy-monitor.toml /opt/auth/config/
```

### Step 3 — Update runtime references

Update **only** the process start commands and nginx references to point to:

```
/opt/auth/config/oauth2-proxy.toml
/opt/auth/config/oauth2-proxy-monitor.toml
```

> Behaviour remains identical; only the paths change.

### Step 4 — Remove `/etc/oauth2-proxy` (after validation)

```bash
sudo rmdir /etc/oauth2-proxy
```

---

## 6) Ports (validated)

- `127.0.0.1:4180` — oauth2-proxy
- `127.0.0.1:8092` — manage-portal
- `127.0.0.1:8088` — monitor-portal (legacy)

---

## 7) Operational control

### 7.1 Identify running auth processes

```bash
ps aux | grep -i oauth2-proxy | grep -v grep
```

### 7.2 Safe restart procedure

Restart **one instance at a time** to avoid a total admin outage:

```bash
sudo pkill -f 'oauth2-proxy.*oauth2-proxy.toml'
/usr/local/bin/oauth2-proxy --config /opt/auth/config/oauth2-proxy.toml &
```

Repeat for the monitor instance only if required.

---

## 8) Dependencies & blast radius

### Downstream dependencies

- Manage Portal (CORE)
- Monitor Portal (LEGACY)

If oauth2-proxy is unavailable:
- Admin UIs are inaccessible
- Backend services continue running but are unreachable

---

## 9) Known risks (accepted)

- Two instances increases operational complexity
- No systemd supervision yet

These risks are accepted until consolidation is explicitly approved.

---

## 10) Validation checklist

After any change:

- [ ] Both oauth2-proxy processes running
- [ ] nginx listening on :80/:443
- [ ] Manage Portal accessible
- [ ] Login works
- [ ] Unauthenticated access blocked

---

## 11) GitHub requirement (mandatory)

When updating auth runtime or documentation:

```bash
cd <auth-repo>
mkdir -p runbooks
cp oauth2-proxy_runbook.md runbooks/oauth2-proxy_runbook.md

git add -A
git commit -m "Update authoritative oauth2-proxy runbook"

git push
```

---

## 12) Completion rule

When work on authentication is completed:
- Provide the **current runbook**
- Incorporate any drift
- Re-issue this document as authoritative
