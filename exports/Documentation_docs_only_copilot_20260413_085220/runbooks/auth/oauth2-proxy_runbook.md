<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# oauth2-proxy — Authoritative Runbook (ZaheZone)

**Component:** oauth2-proxy (Authentication Gateway)  
**Classification:** INFRA (shared upstream dependency)  
**Authoritative runtime location:** `/opt/auth`  
**Last validated:** 2026-04-12

---

## 1) Purpose

- Provide authentication and session enforcement in front of ZaheZone internal admin services.
- Ensure backend services remain bound to localhost and unauthenticated.
- Act as the single supported authentication boundary for admin interfaces.

---

## 2) Scope / Responsibilities

### Does
- Enforce authentication via Microsoft Entra ID (OIDC).
- Maintain secure session cookies.
- Protect access to Manage Portal and Monitor Portal.

### Does NOT
- Does not run inside a container.
- Does not store secrets in Git.
- Does not expose backend services directly to the internet.

---

## 3) Runtime Architecture

### High-level authentication flow
```text
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

### Runtime model (LIVE)
- Native systemd-managed processes
- No Docker or Compose usage

### Binary
- /usr/local/bin/oauth2-proxy

### Instances
| Instance | systemd unit | Config file |
|--------|-------------|-------------|
| Main Auth | oauth2-proxy.service | /opt/auth/config/oauth2-proxy.toml |
| Monitor Auth | oauth2-proxy-monitor.service | /opt/auth/config/oauth2-proxy-monitor.toml |

---

## 4) Dependencies

### Upstream
- Microsoft Entra ID (OIDC)
- nginx reverse proxy

### Downstream
- Manage Portal (localhost:8092)
- Monitor Portal (localhost:8088)

---

## 5) Data / Storage

### Configuration
- /opt/auth/config/oauth2-proxy.toml
- /opt/auth/config/oauth2-proxy-monitor.toml

### Secrets
- Secrets must not be committed to Git.
- Runtime secrets are provided via protected env/config files only.

---

## 6) Operational Lifecycle

### Start
```bash
sudo systemctl start oauth2-proxy.service
sudo systemctl start oauth2-proxy-monitor.service
```

### Stop
```bash
sudo systemctl stop oauth2-proxy.service
sudo systemctl stop oauth2-proxy-monitor.service
```

### Restart (MANDATORY: one at a time)
```bash
sudo systemctl restart oauth2-proxy.service
sudo systemctl status oauth2-proxy.service --no-pager
```

```bash
sudo systemctl restart oauth2-proxy-monitor.service
sudo systemctl status oauth2-proxy-monitor.service --no-pager
```

### Upgrade
- Update binary and/or config as required.
- Reload systemd if unit files change:
```bash
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
```
- Restart instances one at a time.
- Validate authentication and portal access.

### Rollback
- Restore previous known-good config from Git.
- Restart affected service only.
- Validate access.

---

## 7) Validation Checklist

- [ ] oauth2-proxy.service is active (running)
- [ ] oauth2-proxy-monitor.service is active (running)
- [ ] nginx listening on :80 and :443
- [ ] oauth2-proxy listening on 127.0.0.1:4180
- [ ] Manage Portal login works
- [ ] Monitor Portal login works
- [ ] Unauthenticated access is blocked

---

## 8) Failure Modes & Recovery

### Login loop or HTTP 500 errors
```bash
sudo journalctl -u oauth2-proxy.service -n 200 --no-pager
sudo journalctl -u oauth2-proxy-monitor.service -n 200 --no-pager
```

### Portal unreachable
```bash
sudo ss -lntp | egrep '80|443|4180|8092|8088'
```

### One portal failing
- Restart only the relevant oauth2-proxy instance.
- Confirm correct config path under /opt/auth/config.

---

## 9) Change Log

- 2026-04-12 — Auth runtime aligned to /opt/auth/config, systemd units validated, documentation centralised under /opt/Documentation.
