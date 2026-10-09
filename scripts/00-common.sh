#!/usr/bin/env bash
set -euo pipefail

K8S_MINOR="v1.37"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================"
echo " Kubernetes common node bootstrap"
echo "================================================"

echo "==> Updating package index"
apt-get update

echo "==> Installing base dependencies"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gpg \
  containerd

echo "==> Disabling swap"
swapoff -a

# Disable swap persistently if present in fstab.
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

echo "==> Configuring kernel modules"

cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "==> Configuring sysctl"

cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo "==> Configuring containerd"

mkdir -p /etc/containerd

containerd config default >/etc/containerd/config.toml

sed -i \
  's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

systemctl enable containerd
systemctl restart containerd

echo "==> Configuring Kubernetes repository"

mkdir -p /etc/apt/keyrings
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL \
  "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor \
  -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /
EOF

apt-get update

echo "==> Installing Kubernetes components"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  kubelet \
  kubeadm \
  kubectl

apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo "==> Installing Kubernetes host firewall helper"

install \
  -m 0755 \
  "${SCRIPT_DIR}/k8s-host-firewall.sh" \
  /usr/local/sbin/k8s-host-firewall.sh

cat >/etc/systemd/system/k8s-host-firewall.service <<'EOF'
[Unit]
Description=Kubernetes host firewall bootstrap
After=network-online.target
Wants=network-online.target
Before=kubelet.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/k8s-host-firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable k8s-host-firewall.service
systemctl restart k8s-host-firewall.service

echo
echo "================================================"
echo " Common Kubernetes bootstrap complete"
echo "================================================"
echo
echo "containerd:"
containerd --version

echo
echo "kubeadm:"
kubeadm version -o short

echo
echo "kubelet:"
kubelet --version

echo
echo "kubectl:"
kubectl version --client