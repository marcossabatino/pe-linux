# Linux SRE / Platform Engineering Portfolio

Production-grade shell scripts for Linux infrastructure operations — built for SRE, DevOps, and Platform Engineering roles.

Each script is self-contained, configurable via environment variables, and designed to integrate with alerting systems (Slack, PagerDuty).

---

## Scripts

### 01 — System Health Dashboard

Real-time terminal dashboard showing CPU, memory, disk, load average, network I/O, and top processes with color-coded thresholds.

```bash
bash 01-health-dashboard/health-dashboard.sh           # live refresh every 5s
bash 01-health-dashboard/health-dashboard.sh --once    # single snapshot
ALERT_CPU=70 REFRESH_INTERVAL=10 bash 01-health-dashboard/health-dashboard.sh
```

**Key features:** color-coded bars, configurable thresholds, zero dependencies beyond coreutils.

---

### 02 — Log Anomaly Detector

Parses nginx, Apache, syslog, and generic application logs. Detects error rate spikes, suspicious security patterns (SQLi, path traversal, command injection), and high-latency responses.

```bash
bash 02-log-anomaly-detector/log-anomaly-detector.sh /var/log/nginx/access.log --type nginx
bash 02-log-anomaly-detector/log-anomaly-detector.sh /var/log/app.log --follow
bash 02-log-anomaly-detector/log-anomaly-detector.sh /var/log/nginx/access.log -o report.md
```

**Key features:** auto-detects log format, real-time follow mode, security pattern scan, markdown report output.

---

### 03 — SSL Certificate Monitor

Checks TLS certificate expiry across multiple domains. Sends Slack alerts when certificates are within the warning or critical threshold.

```bash
bash 03-ssl-monitor/ssl-monitor.sh google.com github.com mysite.com
bash 03-ssl-monitor/ssl-monitor.sh --file domains.txt --slack "$SLACK_WEBHOOK"
bash 03-ssl-monitor/ssl-monitor.sh mysite.com:8443 --output json
```

**Key features:** multi-domain batch check, custom ports, Slack alerting, JSON/CSV/table output, exits non-zero on critical (cron-friendly).

---

### 04 — Kubernetes Pod Health Checker

Detects unhealthy pods across namespaces: `CrashLoopBackOff`, `OOMKilled`, `ImagePullBackOff`, excessive restarts, and pods stuck in `Pending`. Surfaces actionable `kubectl` commands for each issue.

```bash
bash 04-k8s-pod-checker/k8s-pod-checker.sh --namespace production
bash 04-k8s-pod-checker/k8s-pod-checker.sh --context staging --watch
bash 04-k8s-pod-checker/k8s-pod-checker.sh --slack "$SLACK_WEBHOOK"
```

**Key features:** all-namespaces scan, watch mode, Slack alerts, kubectl remediation hints per pod.

---

### 05 — Blue-Green Deployment Helper

Orchestrates blue-green traffic switching with healthcheck validation and automatic rollback on failure. Works with Docker Compose and nginx upstreams.

```bash
bash 05-blue-green-deploy/blue-green-deploy.sh \
  --app myapi \
  --new-version v2.1.0 \
  --health-url http://localhost:8081/health \
  --compose-file docker-compose.prod.yml

# Dry-run to preview steps
bash 05-blue-green-deploy/blue-green-deploy.sh --app myapi --new-version v2.1.0 \
  --health-url http://localhost:8081/health --dry-run
```

**Key features:** configurable healthcheck retries, automatic rollback, nginx reload, Slack notifications, dry-run mode.

---

### 06 — Backup with Retention Policy

Creates compressed backups with SHA-256 integrity verification and a daily/weekly/monthly rotation policy. Supports gzip, zstd, and bzip2 compression.

```bash
bash 06-backup-retention/backup-retention.sh /var/www /etc/nginx --dest /mnt/backups --name webserver
bash 06-backup-retention/backup-retention.sh --list --dest /mnt/backups
bash 06-backup-retention/backup-retention.sh --restore /mnt/backups/webserver-daily-2024-01-15.tar.gz --to /tmp/restore
```

**Key features:** SHA-256 checksum verification, retention rotation (7 daily / 4 weekly / 6 monthly), restore with integrity check, multiple compression backends.

---

### 07 — CIS Benchmark Checker

Audits Linux host hardening against the CIS Linux Benchmark v2. Checks SSH configuration, user accounts, file permissions, network settings, running services, and auditd.

```bash
bash 07-cis-benchmark/cis-benchmark.sh
bash 07-cis-benchmark/cis-benchmark.sh --score            # score only
bash 07-cis-benchmark/cis-benchmark.sh --report out.md   # markdown report
```

**Sample output:**
```
Score : 50%
Grade : D
PASS  : 18   FAIL : 15   WARN : 3
```

**Key features:** 35+ checks across 7 categories, A–F grading, markdown report export, non-root safe.

---

### 10 — Incident Runbook Automator

Executes a structured triage checklist (system, processes, logs, network, storage) and saves a markdown report. Designed to be the first script run during an incident.

```bash
bash 10-incident-runbook/incident-runbook.sh \
  --service api-gateway \
  --severity P1 \
  --url http://api.internal/health \
  --slack "$SLACK_WEBHOOK"

# Preview steps without executing
bash 10-incident-runbook/incident-runbook.sh --service myapp --dry-run
```

**Key features:** 5-section triage (system → processes → logs → network → storage), markdown report with timestamps, Slack notifications on start and completion, dry-run mode.

---

## Requirements

| Script | Dependencies |
|--------|-------------|
| health-dashboard | `coreutils`, `procps` |
| log-anomaly-detector | `grep`, `awk`, `curl` |
| ssl-monitor | `openssl`, `curl` |
| k8s-pod-checker | `kubectl`, `python3` |
| blue-green-deploy | `curl`, `docker` (optional), `nginx` (optional) |
| backup-retention | `tar`, `sha256sum` |
| cis-benchmark | `coreutils`, `systemctl`, `sysctl` |
| incident-runbook | `coreutils`, `curl`, `ss` |

---

## Quick Start

```bash
git clone git@github.com:marcossabatino/pe-linux.git
cd pe-linux
make install-deps   # installs shellcheck and common tools

make demo-health    # run health dashboard (single snapshot)
make demo-ssl       # check google.com github.com cloudflare.com
make demo-cis       # audit this host against CIS Benchmark
make demo-incident  # dry-run incident triage
make lint           # run shellcheck on all scripts
```

---

## Environment Variables

Most scripts are configurable without flags:

```bash
# ssl-monitor
WARN_DAYS=30 CRIT_DAYS=7 SLACK_WEBHOOK="https://..." bash 03-ssl-monitor/ssl-monitor.sh domain.com

# health-dashboard
ALERT_CPU=80 ALERT_MEM=90 REFRESH_INTERVAL=10 bash 01-health-dashboard/health-dashboard.sh

# blue-green-deploy
DRY_RUN=true SLACK_WEBHOOK="https://..." bash 05-blue-green-deploy/blue-green-deploy.sh ...

# incident-runbook
REPORT_DIR=/var/log/incidents bash 10-incident-runbook/incident-runbook.sh --service myapp
```

---

## About

Built as a portfolio for SRE / DevOps / Platform Engineering contract roles.
Scripts target production Linux environments (Ubuntu, RHEL, Fedora) and follow defensive shell programming practices.

> **Contributions and feedback welcome** — open an issue or PR.
