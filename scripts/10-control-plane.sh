#!/usr/bin/env bash
set -euo pipefail

# Do not overwrite admin kubeconfig or retry init on an existing/partial cluster.
if sudo test -e /etc/kubernetes/admin.conf || sudo test -e /etc/kubernetes/kubelet.conf; then
  echo "Existing Kubernetes configuration: inspect the cluster before retrying init." >&2
  exit 1
fi
if [[ -e "$HOME/.kube/config" ]]; then
  echo "Existing kubeconfig: back it up or choose a clean account first." >&2
  exit 1
fi
K8S_VERSION=$(kubeadm version -o short)
[[ $K8S_VERSION == v1.37.* ]] || { echo "kubeadm v1.37.x required." >&2; exit 1; }

POD_CIDR="192.168.0.0/16"

PRIVATE_IP="${PRIVATE_IP:-$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')}"
[[ -n $PRIVATE_IP ]] || { echo "Set PRIVATE_IP to the node private IPv4 address." >&2; exit 1; }

echo "Control plane IP: ${PRIVATE_IP}"

sudo kubeadm init \
  --kubernetes-version="${K8S_VERSION}" \
  --cri-socket=unix:///run/containerd/containerd.sock \
  --apiserver-advertise-address="${PRIVATE_IP}" \
  --pod-network-cidr="${POD_CIDR}"

umask 077
mkdir -p "$HOME/.kube"
sudo install -m 0600 /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo
echo "Control plane initialized."
echo
echo "Worker join command:"
sudo kubeadm token create --kubeconfig /etc/kubernetes/admin.conf --print-join-command
echo "Calico operator/CRDs and the local installation manifest must still be installed."