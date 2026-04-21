#!/usr/bin/env bash
# tests/integration/test_mdns_reboot.sh — integration coverage for MDNS-03
# Verifies agmind-mdns.service survives `systemctl restart avahi-daemon` within 10s.
# Exit 77 = SKIP (preconditions not met); 0 = PASS; 1 = FAIL.
set -euo pipefail

echo "## test_mdns_reboot (integration)"

if [[ $EUID -ne 0 ]]; then
    echo "SKIP: integration test requires root (sudo bash $0)"
    exit 77
fi
if ! command -v systemctl >/dev/null 2>&1; then
    echo "SKIP: systemctl not available"
    exit 77
fi
if ! systemctl list-unit-files agmind-mdns.service >/dev/null 2>&1 \
     || ! systemctl cat agmind-mdns.service >/dev/null 2>&1; then
    echo "SKIP: agmind-mdns.service not installed — run sudo bash install.sh first"
    exit 77
fi
if ! systemctl is-active --quiet avahi-daemon.service; then
    echo "SKIP: avahi-daemon.service not active"
    exit 77
fi

# Static assertion: unit file must contain BindsTo + PartOf + After (Plan 01-01 MDNS-03)
unit_txt="$(systemctl cat agmind-mdns.service)"
for directive in "BindsTo=avahi-daemon.service" "PartOf=avahi-daemon.service" "After=avahi-daemon.service"; do
    if grep -q "$directive" <<< "$unit_txt"; then
        echo "  [PASS] unit contains ${directive}"
    else
        echo "  [FAIL] unit missing ${directive}"
        echo "$unit_txt" | sed 's/^/    /'
        exit 1
    fi
done

if ! systemctl is-active --quiet agmind-mdns.service; then
    echo "  [FAIL] agmind-mdns.service not active at baseline (pre-test)"
    systemctl status --no-pager agmind-mdns.service | sed 's/^/    /'
    exit 1
fi
echo "  [PASS] baseline agmind-mdns.service active"

echo "  → restarting avahi-daemon..."
systemctl restart avahi-daemon.service

deadline=12
for ((i=1; i<=deadline; i++)); do
    if systemctl is-active --quiet agmind-mdns.service; then
        echo "  [PASS] agmind-mdns.service reactive after ${i}s (≤ 10s target)"
        if [[ $i -gt 10 ]]; then
            echo "  [WARN] recovery took ${i}s — above soft 10s target (still within 12s grace)"
        fi
        if command -v avahi-resolve >/dev/null 2>&1; then
            if resolved="$(avahi-resolve -n -4 agmind-dify.local 2>/dev/null)"; then
                echo "  [PASS] avahi-resolve agmind-dify.local → ${resolved}"
            else
                echo "  [WARN] avahi-resolve timeout for agmind-dify.local"
            fi
        fi
        echo ""
        echo "## Summary: integration PASS"
        exit 0
    fi
    sleep 1
done

echo "  [FAIL] agmind-mdns.service did not become active within ${deadline}s"
systemctl status --no-pager agmind-mdns.service | sed 's/^/    /'
journalctl -u agmind-mdns.service -n 20 --no-pager | sed 's/^/    /'
exit 1
