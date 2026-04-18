SHELL := /usr/bin/env bash
SCRIPTS := $(shell find . -name '*.sh' | sort)

.PHONY: lint test demo-health demo-ssl demo-logs demo-cis demo-leaks demo-incident install-deps help

help:
	@echo ""
	@echo "Linux SRE Portfolio — Makefile"
	@echo ""
	@echo "  make lint              Run shellcheck on all scripts"
	@echo "  make test              Run all available tests"
	@echo "  make demo-health       Demo: System Health Dashboard"
	@echo "  make demo-ssl          Demo: SSL Monitor (public domains)"
	@echo "  make demo-logs         Demo: Log Anomaly Detector (syslog)"
	@echo "  make demo-cis          Demo: CIS Benchmark Checker"
	@echo "  make demo-leaks        Demo: Resource Leak Finder"
	@echo "  make demo-incident     Demo: Incident Runbook (dry-run)"
	@echo "  make install-deps      Install: shellcheck, asciinema, curl, openssl"
	@echo ""

lint:
	@echo "Running shellcheck on all scripts..."
	@if command -v shellcheck &>/dev/null; then \
		shellcheck --severity=warning $(SCRIPTS) && echo "All checks passed." ; \
	else \
		echo "shellcheck not found. Run: make install-deps"; \
	fi

test: lint
	@echo ""
	@echo "Running integration tests..."
	@bash 01-health-dashboard/health-dashboard.sh --once
	@bash 03-ssl-monitor/ssl-monitor.sh google.com --output table
	@bash 07-cis-benchmark/cis-benchmark.sh --score
	@bash 08-resource-leak-finder/resource-leak-finder.sh
	@echo ""
	@echo "All tests passed."

demo-health:
	@bash 01-health-dashboard/health-dashboard.sh --once

demo-ssl:
	@bash 03-ssl-monitor/ssl-monitor.sh \
		google.com github.com cloudflare.com expired.badssl.com

demo-logs:
	@if [ -f /var/log/syslog ]; then \
		bash 02-log-anomaly-detector/log-anomaly-detector.sh /var/log/syslog; \
	elif [ -f /var/log/messages ]; then \
		bash 02-log-anomaly-detector/log-anomaly-detector.sh /var/log/messages; \
	else \
		echo "No syslog found. Try: bash 02-log-anomaly-detector/log-anomaly-detector.sh <logfile>"; \
	fi

demo-cis:
	@bash 07-cis-benchmark/cis-benchmark.sh

demo-leaks:
	@bash 08-resource-leak-finder/resource-leak-finder.sh

demo-incident:
	@bash 10-incident-runbook/incident-runbook.sh \
		--service demo-app \
		--severity P2 \
		--reporter "$(USER)" \
		--dry-run

install-deps:
	@echo "Installing dependencies..."
	@if command -v apt-get &>/dev/null; then \
		sudo apt-get install -y shellcheck curl openssl procps; \
	elif command -v dnf &>/dev/null; then \
		sudo dnf install -y ShellCheck curl openssl procps-ng; \
	elif command -v yum &>/dev/null; then \
		sudo yum install -y ShellCheck curl openssl procps; \
	fi
	@echo "For asciinema: https://asciinema.org/docs/installation"
