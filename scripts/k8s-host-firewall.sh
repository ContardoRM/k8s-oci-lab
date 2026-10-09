#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
command -v iptables >/dev/null
# Fail if the table is inaccessible instead of treating every error as absent rules.
iptables -w 10 -S INPUT >/dev/null
iptables -w 10 -S FORWARD >/dev/null

PRIVATE_CIDR="${PRIVATE_CIDR:-10.0.1.0/24}"

echo "==> Configuring Kubernetes host firewall"

add_input_tcp() {
  local port="$1"

  if ! iptables -w 10 -C INPUT \
      -s "${PRIVATE_CIDR}" \
      -p tcp \
      --dport "${port}" \
      -j ACCEPT 2>/dev/null; then

    iptables -w 10 -I INPUT 1 \
      -s "${PRIVATE_CIDR}" \
      -p tcp \
      --dport "${port}" \
      -j ACCEPT
  fi
}

# IPIP is IP protocol 4, not TCP/UDP port 4.
if ! iptables -w 10 -C INPUT -s "${PRIVATE_CIDR}" -p 4 -j ACCEPT 2>/dev/null; then
  iptables -w 10 -I INPUT 1 -s "${PRIVATE_CIDR}" -p 4 -j ACCEPT
fi

# Calico BGP
add_input_tcp 179

# Calico Typha
add_input_tcp 5473

# Kubernetes API
add_input_tcp 6443

# kubelet API
add_input_tcp 10250

# OCI Ubuntu images include a FORWARD reject that conflicts
# with Kubernetes/Calico forwarding.
while iptables -w 10 -C FORWARD \
  -j REJECT \
  --reject-with icmp-host-prohibited 2>/dev/null; do

  echo "Removing OCI FORWARD reject"
  iptables -w 10 -D FORWARD \
    -j REJECT \
    --reject-with icmp-host-prohibited
done

echo "==> Host firewall configured"