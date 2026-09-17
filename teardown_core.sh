#!/usr/bin/env bash
if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run with sudo: sudo ./teardown_core.sh"
    exit 1
fi

echo "[+] Stopping free5GC network functions..."
killall -9 -q amf smf nrf udr udm pcf ausf nssf chf nef bsf upf webconsole 2>/dev/null || true
pkill -9 -f "free5gc/bin" 2>/dev/null || true

echo "[+] Removing tunnel and SBI dummy devices..."
ip link delete upfgtp 2>/dev/null || true
ip link delete sbi_net 2>/dev/null || true

echo "[+] Flushing NAT rules..."
iptables -F FORWARD
iptables -t nat -F POSTROUTING

echo "[+] Resetting database NF cache..."
mongosh free5gc --eval "db.NfProfile.deleteMany({})" 2>/dev/null || mongo free5gc --eval "db.NfProfile.deleteMany({})" 2>/dev/null || true

echo "[SUCCESS] Core network cleanly terminated."
