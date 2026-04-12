# 3CX Collector (ZaheZone)

This repository contains the ZaheZone 3CX Collector.

## What it does
- Polls 3CX instances via token auth (XAPI)
- Writes metrics to monitor_metrics
- Writes credentials are read from monitor_secrets
- Updates heartbeat for Grafana Up/Down + Last Seen

## Files
- `collector.py` — main collector
- `Dockerfile` — build container
- `config.yaml.example` — example config
- `3cx-collector.service` — systemd unit for autostart
- `3cx-collector_runbook.md` — authoritative runbook

## Build & Run
```bash
docker build --no-cache -t 3cx-collector:latest .

docker run -d --name 3cx-collector   --network collector_internal_net   --env-file /opt/3cx-collector/.env   3cx-collector:latest
```

