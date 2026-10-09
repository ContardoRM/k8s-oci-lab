#!/usr/bin/env bash
set -euo pipefail

# Pass arguments separately, never an executable shell command string.
if [[ $# -ne 3 ]]; then
  echo "Usage: sudo bash $0 HOST:6443 TOKEN sha256:CA_HASH" >&2
  exit 1
fi

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

[[ $1 =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]] || {
  echo "Invalid endpoint." >&2
  exit 1
}

[[ $2 =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]] || {
  echo "Invalid token." >&2
  exit 1
}

[[ $3 =~ ^sha256:[a-f0-9]{64}$ ]] || {
  echo "Invalid CA hash." >&2
  exit 1
}

if [[ -e /etc/kubernetes/kubelet.conf || -e /etc/kubernetes/bootstrap-kubelet.conf ]]; then
  echo "Existing or partial node configuration: inspect it before joining again." >&2
  exit 1
fi

kubeadm join "$1" \
  --token "$2" \
  --discovery-token-ca-cert-hash "$3" \
  --cri-socket unix:///run/containerd/containerd.sock

echo "Worker joined. Verify the node reaches Ready and Calico starts on it."