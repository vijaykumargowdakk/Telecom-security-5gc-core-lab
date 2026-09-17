#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    5G CORE NETWORK (free5GC) DYNAMIC SETUP       "
echo "=================================================="

if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run this script with sudo: sudo ./setup_and_start_core.sh [interface]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Interface Detection
AVAILABLE_INTERFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo\|dummy\|upf\|sbi\|docker\|tun"))

if [ -n "$1" ]; then
    PHYSICAL_IF="$1"
else
    echo "[*] Detected network interfaces: ${AVAILABLE_INTERFACES[*]}"
    DEFAULT_IF=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
    read -p "[?] Enter physical interface to use [Default: $DEFAULT_IF]: " INPUT_IF
    PHYSICAL_IF="${INPUT_IF:-$DEFAULT_IF}"
fi

if [ -z "$PHYSICAL_IF" ] || ! ip link show "$PHYSICAL_IF" >/dev/null 2>&1; then
    echo "[-] Error: Interface '$PHYSICAL_IF' is invalid."
    exit 1
fi

SERVER_IP=$(ip -4 addr show dev "$PHYSICAL_IF" | grep -m1 inet | awk '{print $2}' | cut -d'/' -f1)
if [ -z "$SERVER_IP" ]; then
    echo "[-] Error: No IPv4 address found on $PHYSICAL_IF."
    exit 1
fi

echo "[+] Using Interface: $PHYSICAL_IF"
echo "[+] Detected Core IP: $SERVER_IP"

# 2. Kernel Routing & Forwarding
echo "[+] Configuring Kernel IP forwarding and routing..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sysctl -w "net.ipv4.conf.$PHYSICAL_IF.rp_filter=0" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.lo.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
systemctl stop ufw >/dev/null 2>&1 || true

# 3. Dummy Interface for SBI (10.0.0.1/24)
echo "[+] Configuring sbi_net dummy interface (10.0.0.1/24)..."
ip link add dev sbi_net type dummy 2>/dev/null || true
ip addr add 10.0.0.1/24 dev sbi_net 2>/dev/null || true
ip link set sbi_net up 2>/dev/null || true
ip route replace local 10.0.0.0/24 dev sbi_net

# 4. NAT Forwarding
iptables -F FORWARD
iptables -A FORWARD -j ACCEPT
iptables -t nat -C POSTROUTING -o "$PHYSICAL_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$PHYSICAL_IF" -j MASQUERADE

# 5. Modules & Database
echo "[+] Checking gtp5g module..."
if ! lsmod | grep -q "gtp5g"; then
    modprobe udp_tunnel 2>/dev/null || true
    modprobe gtp5g 2>/dev/null || true
    if ! lsmod | grep -q "gtp5g"; then
        echo "[-] Error: gtp5g module is not loaded."
        exit 1
    fi
fi

echo "[+] Starting MongoDB service..."
systemctl start mongod
mongosh free5gc --eval "db.NfProfile.deleteMany({})" 2>/dev/null || mongo free5gc --eval "db.NfProfile.deleteMany({})" 2>/dev/null || true

# 6. Safe Configuration Updates via Python
echo "[+] Updating core configuration files with IP: $SERVER_IP..."
python3 - << PYEOF
import re

# Update amfcfg.yaml ngapIpList
with open("$SCRIPT_DIR/config/amfcfg.yaml", "r") as f:
    lines = f.readlines()

out = []
in_ngap = False
for line in lines:
    if "ngapIpList:" in line:
        out.append("  ngapIpList:\n")
        out.append("    - $SERVER_IP\n")
        in_ngap = True
    elif in_ngap and line.strip().startswith("-"):
        continue  # Skip old list items
    else:
        in_ngap = False
        out.append(line)

with open("$SCRIPT_DIR/config/amfcfg.yaml", "w") as f:
    f.writelines(out)

# Update upfcfg.yaml N3 GTP-U IP
with open("$SCRIPT_DIR/config/upfcfg.yaml", "r") as f:
    upf = f.read()
upf = re.sub(r'(- type: N3\s+addr:\s*)[0-9\.]+', r'\g<1>$SERVER_IP', upf)
with open("$SCRIPT_DIR/config/upfcfg.yaml", "w") as f:
    f.write(upf)

# Ensure smfcfg.yaml PFCP bindings stay aligned
with open("$SCRIPT_DIR/config/smfcfg.yaml", "r") as f:
    smf = f.read()
smf = re.sub(r'nodeID: 10\.0\.0\.[0-9]+(\s*# the Node ID of this SMF)', r'nodeID: 10.0.0.2\1', smf)
smf = re.sub(r'listenAddr: 10\.0\.0\.[0-9]+(\s*# the IP/FQDN of N4 interface on this SMF)', r'listenAddr: 10.0.0.2\1', smf)
smf = re.sub(r'externalAddr: 10\.0\.0\.[0-9]+(\s*# the IP/FQDN of N4 interface on this SMF)', r'externalAddr: 10.0.0.2\1', smf)
smf = re.sub(r'(UPF:.*?\n\s+type: UPF.*?\n\s+nodeID:\s*)10\.0\.0\.[0-9]+', r'\g<1>10.0.0.1', smf, flags=re.DOTALL)
smf = re.sub(r'(UPF:.*?\n\s+type: UPF.*?\n\s+nodeID:.*?\n\s+addr:\s*)10\.0\.0\.[0-9]+', r'\g<1>10.0.0.1', smf, flags=re.DOTALL)
with open("$SCRIPT_DIR/config/smfcfg.yaml", "w") as f:
    f.write(smf)
PYEOF

# 7. Cleanup & Startup
echo "[+] Cleaning up previous instances..."
killall -q -9 amf smf nrf udr udm pcf ausf nssf chf nef bsf upf webconsole 2>/dev/null || true
pkill -9 -f "free5gc/bin" 2>/dev/null || true
ip link delete upfgtp 2>/dev/null || true
sleep 2

echo "[+] Starting free5GC Core Network..."
cd "$SCRIPT_DIR"
nohup ./run.sh > free5gc_startup.log 2>&1 &
FREE5GC_PID=$!
echo "[+] free5GC started (PID: $FREE5GC_PID). Log: free5gc_startup.log"

# Wait for AMF to bind
echo "[*] Waiting for AMF to bind to $SERVER_IP:38412..."
COUNT=0
while ! ss -l -n -a --sctp | grep -q "$SERVER_IP:38412"; do
    sleep 1
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge 20 ]; then
        echo "[-] Timeout: AMF did not bind to $SERVER_IP:38412. Error details from log:"
        grep -aiE "amf|fatal|panic|error" free5gc_startup.log | tail -n 15
        exit 1
    fi
done
echo "[SUCCESS] AMF is listening on $SERVER_IP:38412."

# Start Webconsole
if [ -f "$SCRIPT_DIR/webconsole/bin/webconsole" ]; then
    cd "$SCRIPT_DIR/webconsole"
    nohup ./bin/webconsole > "$SCRIPT_DIR/webconsole.log" 2>&1 &
    echo "[+] Webconsole running on http://127.0.0.1:5000"
fi

echo "=================================================="
echo " [SUCCESS] 5G CORE IS ACTIVE AND READY"
echo " Tell participants to connect to Core IP: $SERVER_IP"
echo "=================================================="
