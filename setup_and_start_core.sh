#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    5G CORE NETWORK (free5GC) DYNAMIC SETUP       "
echo "=================================================="

if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run this script with sudo: sudo ./setup_and_start_core.sh [interface]"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Detect or prompt for network interface
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
    echo "[-] Error: No IPv4 address assigned to $PHYSICAL_IF. Ensure the network cable/Wi-Fi is connected."
    exit 1
fi

echo "[+] Using Interface: $PHYSICAL_IF"
echo "[+] Detected Core IP: $SERVER_IP"

# 2. Host Kernel and Routing Policies
echo "[+] Configuring Kernel IP forwarding and routing..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sysctl -w "net.ipv4.conf.$PHYSICAL_IF.rp_filter=0" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.lo.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
systemctl stop ufw >/dev/null 2>&1 || true

# 3. Dummy SBI Network (10.0.0.0/24) for Service-Based Architecture
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

# 5. Kernel Modules and MongoDB
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

# 6. Dynamically patch configuration files with SERVER_IP
echo "[+] Updating core configuration files with IP: $SERVER_IP..."
CONFIG_DIR="$SCRIPT_DIR/config"
if [ ! -d "$CONFIG_DIR" ]; then
    echo "[-] Error: config directory not found at $CONFIG_DIR"
    exit 1
fi

# Patch AMF NGAP listener to listen on the dynamic host IP
if [ -f "$CONFIG_DIR/amfcfg.yaml" ]; then
    sed -i -E "s/ngapIpList:.*/ngapIpList: [\"$SERVER_IP\"]/g" "$CONFIG_DIR/amfcfg.yaml"
fi

# Patch UPF GTP-U (N3) address to the dynamic host IP
if [ -f "$CONFIG_DIR/upfcfg.yaml" ]; then
    sed -i -E "/type: N3/,/addr:/ s/addr: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/addr: $SERVER_IP/" "$CONFIG_DIR/upfcfg.yaml"
fi

# Ensure SMF PFCP listenAddr/nodeID is 10.0.0.2 and target UPF is 10.0.0.1
if [ -f "$CONFIG_DIR/smfcfg.yaml" ]; then
    sed -i '/pfcp:/,/assocFailAlertInterval:/ s/nodeID: .*/nodeID: 10.0.0.2/' "$CONFIG_DIR/smfcfg.yaml"
    sed -i '/pfcp:/,/assocFailAlertInterval:/ s/listenAddr: .*/listenAddr: 10.0.0.2/' "$CONFIG_DIR/smfcfg.yaml"
    sed -i '/pfcp:/,/assocFailAlertInterval:/ s/externalAddr: .*/externalAddr: 10.0.0.2/' "$CONFIG_DIR/smfcfg.yaml"
    sed -i '/UPF:/,/interfaces:/ s/nodeID: .*/nodeID: 10.0.0.1/' "$CONFIG_DIR/smfcfg.yaml"
    sed -i '/UPF:/,/interfaces:/ s/addr: .*/addr: 10.0.0.1/' "$CONFIG_DIR/smfcfg.yaml"
fi

# 7. Terminate any previous instances
echo "[+] Cleaning up any lingering instances..."
killall -q -9 amf smf nrf udr udm pcf ausf nssf chf nef bsf upf webconsole 2>/dev/null || true
pkill -9 -f "free5gc/bin" 2>/dev/null || true
ip link delete upfgtp 2>/dev/null || true
sleep 2

# 8. Start free5GC
echo "[+] Starting free5GC Core Network..."
cd "$SCRIPT_DIR"
nohup ./run.sh > free5gc_startup.log 2>&1 &
FREE5GC_PID=$!
echo "[+] free5GC started (PID: $FREE5GC_PID). Log: free5gc_startup.log"

# Wait for AMF to listen on port 38412
echo "[*] Waiting for AMF to bind to $SERVER_IP:38412..."
COUNT=0
while ! ss -l -n -a --sctp | grep -q "$SERVER_IP:38412"; do
    sleep 1
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge 25 ]; then
        echo "[-] Timeout: AMF did not bind to $SERVER_IP:38412. Check free5gc_startup.log."
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
