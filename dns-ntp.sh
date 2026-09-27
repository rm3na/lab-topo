#!/usr/bin/env bash
# =============================================================================
#  setup-dns-ntp.sh — DNS (BIND9) + NTP (chrony) for the Avatar/RAG POC
#  Target: Ubuntu 24.04 VM at 10.3.50.70 (VLAN 50 / 10.3.50.0/24)
#  Run as root:  sudo bash setup-dns-ntp.sh
#  Safe to re-run: config files are rewritten and the zone serial is bumped.
# =============================================================================

# ============================ SETTINGS — EDIT ME =============================
DOMAIN="ik.lab"                      # POC DNS zone
DNS_IP="10.3.50.70"               # this VM
PREFIX="24"
GATEWAY="10.3.50.254"
NET_CIDR="10.3.50.0/24"
REVERSE_ZONE="50.3.10.in-addr.arpa"

# Networks allowed to query / recurse and to use NTP
# (add the university subnet(s) here once known, for conditional forwarding)
TRUSTED_NETS=("10.3.50.0/24" "127.0.0.1")

# Upstream resolvers for internet names (IKUSI resolvers if internet DNS is filtered)
FORWARDERS=("1.1.1.1" "8.8.8.8")

# Upstream NTP servers
NTP_UPSTREAM=("0.pool.ntp.org" "1.pool.ntp.org" "2.pool.ntp.org")

# Set a static IP with netplan? (false if you already set it during install —
# changing it over SSH can drop your session)
SET_NETPLAN=false
IFACE=""                             # empty = auto-detect default interface

# Host records: "name ip"  (PTR records are created for 10.3.50.x entries)
RECORDS=(
  "iklabesx05  10.3.50.15"
  "c845a-bmc   10.3.50.66"
  "jump01      10.3.50.67"
  "c845a01     10.3.50.68"
  "k8s-api     10.3.50.68"        # Kubernetes API endpoint (kubeconfig + cert SAN)
  "bcm01       10.3.50.69"        # reserved for BCM head (later)
  "dns01       10.3.50.70"
  "ingress     10.3.50.71"        # MetalLB IP of the ingress controller
  "s3          10.3.50.72"        # MetalLB IP of MinIO S3 API
  "gw          10.3.50.254"
)
# Aliases (CNAME -> target) for published POC services behind the ingress
CNAMES=(
  "ntp            dns01"
  "avatar         ingress"
  "rag-api        ingress"
  "grafana        ingress"
  "minio-console  ingress"
  "*.apps         ingress"         # wildcard: any new app = new Ingress, no DNS change
)
# =============================================================================

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }
log(){ echo -e "\n==> $*"; }

HOSTNAME_SHORT="dns01"
SERIAL="$(date +%Y%m%d%H)"
ZONE_DIR="/etc/bind/zones"

# ------------------------------------------------------------------ netplan --
if [[ "$SET_NETPLAN" == "true" ]]; then
  [[ -n "$IFACE" ]] || IFACE="$(ip -o route show default | awk '{print $5}' | head -1)"
  log "Writing static netplan for $IFACE ($DNS_IP/$PREFIX)"
  cat > /etc/netplan/60-static.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: false
      addresses: [$DNS_IP/$PREFIX]
      routes: [{to: default, via: $GATEWAY}]
      nameservers: {addresses: [127.0.0.1], search: [$DOMAIN]}
EOF
  chmod 600 /etc/netplan/60-static.yaml
  netplan apply
fi

# ----------------------------------------------------------------- packages --
log "Installing bind9, chrony, dnsutils"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y bind9 bind9-utils dnsutils chrony

hostnamectl set-hostname "${HOSTNAME_SHORT}.${DOMAIN}"

# -------------------------------------------------------------- BIND options --
log "Configuring BIND options"
acl_list="$(printf '%s; ' "${TRUSTED_NETS[@]}")"
fwd_list="$(printf '%s; ' "${FORWARDERS[@]}")"

cat > /etc/bind/named.conf.options <<EOF
acl "trusted" { ${acl_list}};

options {
    directory "/var/cache/bind";
    listen-on { 127.0.0.1; ${DNS_IP}; };
    listen-on-v6 { none; };

    allow-query     { trusted; };
    allow-recursion { trusted; };
    allow-transfer  { none; };
    recursion yes;

    forwarders { ${fwd_list}};
    forward only;

    dnssec-validation auto;
    auth-nxdomain no;
};
EOF

cat > /etc/bind/named.conf.local <<EOF
zone "${DOMAIN}" {
    type master;
    file "${ZONE_DIR}/db.${DOMAIN}";
};

zone "${REVERSE_ZONE}" {
    type master;
    file "${ZONE_DIR}/db.${REVERSE_ZONE}";
};
EOF

# ------------------------------------------------------------------- zones --
log "Writing zones for ${DOMAIN} and ${REVERSE_ZONE} (serial ${SERIAL})"
mkdir -p "$ZONE_DIR"
FWD="${ZONE_DIR}/db.${DOMAIN}"
REV="${ZONE_DIR}/db.${REVERSE_ZONE}"

soa() {
cat <<EOF
\$TTL 300
@   IN SOA ${HOSTNAME_SHORT}.${DOMAIN}. hostmaster.${DOMAIN}. (
        ${SERIAL} ; serial
        3600       ; refresh
        600        ; retry
        604800     ; expire
        300 )      ; negative TTL
    IN NS ${HOSTNAME_SHORT}.${DOMAIN}.
EOF
}

{ soa
  for r in "${RECORDS[@]}"; do
    read -r name ip _ <<<"$r"
    printf '%-14s IN A     %s\n' "$name" "$ip"
  done
  for c in "${CNAMES[@]}"; do
    read -r alias target _ <<<"$c"
    printf '%-14s IN CNAME %s\n' "$alias" "$target"
  done
} > "$FWD"

net3="$(echo "$NET_CIDR" | cut -d. -f1-3)"
declare -A seen_ptr=()
{ soa
  for r in "${RECORDS[@]}"; do
    read -r name ip _ <<<"$r"
    # one PTR per IP: the first name listed for an IP wins (e.g. c845a01, not k8s-api)
    if [[ "$ip" == ${net3}.* && -z "${seen_ptr[$ip]:-}" ]]; then
      seen_ptr[$ip]=1
      printf '%-4s IN PTR %s.%s.\n' "${ip##*.}" "$name" "$DOMAIN"
    fi
  done
} > "$REV"

chown -R bind:bind "$ZONE_DIR"

log "Validating BIND configuration"
named-checkconf
named-checkzone "$DOMAIN" "$FWD"
named-checkzone "$REVERSE_ZONE" "$REV"

# ---------------------------------------- local resolver: use BIND itself ---
log "Pointing this VM's resolver at BIND (disabling systemd-resolved stub)"
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/local-bind.conf <<EOF
[Resolve]
DNS=127.0.0.1
Domains=${DOMAIN}
DNSStubListener=no
EOF
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved
systemctl enable --now named
systemctl restart named

# ------------------------------------------------------------------ chrony --
log "Configuring chrony as NTP server"
{
  echo "# Managed by setup-dns-ntp.sh"
  for s in "${NTP_UPSTREAM[@]}"; do echo "pool $s iburst"; done
  for n in "${TRUSTED_NETS[@]}"; do
    [[ "$n" == 127.* ]] || echo "allow $n"
  done
  echo "# keep serving time if upstream is unreachable"
  echo "local stratum 10"
  echo "driftfile /var/lib/chrony/chrony.drift"
  echo "makestep 1.0 3"
  echo "rtcsync"
} > /etc/chrony/chrony.conf
systemctl enable --now chrony
systemctl restart chrony

# --------------------------------------------------------------- firewall --
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  log "Opening ufw for DNS/NTP"
  ufw allow 53/udp; ufw allow 53/tcp; ufw allow 123/udp
fi

# ------------------------------------------------------------------- tests --
log "Tests"
sleep 2
echo "-- forward:";  dig +short @"$DNS_IP" "c845a01.${DOMAIN}"
echo "-- cname:";    dig +short @"$DNS_IP" "avatar.${DOMAIN}"
echo "-- reverse:";  dig +short @"$DNS_IP" -x 10.3.50.68
echo "-- internet:"; dig +short @"$DNS_IP" nvcr.io | head -3 || true
echo "-- chrony:";   chronyc -n sources || true

log "Done. DNS/NTP at ${DNS_IP}, zone ${DOMAIN}."
echo "Point jump01, bcm01 and c845a01 to DNS/NTP ${DNS_IP}, search domain ${DOMAIN}."
