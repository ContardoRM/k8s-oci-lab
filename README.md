# Kubernetes OCI Lab

A hands-on Kubernetes lab built from scratch on **Oracle Cloud Infrastructure (OCI)** using Ubuntu VMs, `kubeadm`, `containerd`, Calico, and Headlamp.

The goal of this project is not to hide Kubernetes behind a managed service, but to understand and reproduce the main components involved in building and operating a small Kubernetes cluster.

The cluster was first installed manually, troubleshooted step by step, and then converted into reusable shell scripts.

---

## What this lab covers

- Kubernetes installation with `kubeadm`
- `containerd` as the container runtime
- Kubernetes v1.37
- Calico networking
- IP-in-IP encapsulation between nodes
- CoreDNS
- kube-proxy
- ClusterIP Services
- Pod-to-Pod networking
- Pod-to-Pod networking across nodes
- Host firewall configuration
- OCI networking requirements
- Worker node bootstrap
- Headlamp as a visual Kubernetes dashboard
- Complete cluster rebuild from clean VMs

---

## Architecture

```text
                         OCI VCN
                      10.0.1.0/24
                           |
          +----------------+----------------+
          |                                 |
          |                                 |
 +------------------+              +------------------+
 |   k8s-cp-01      |              | k8s-worker-01    |
 |                  |              |                  |
 | Control Plane    |              | Worker Node      |
 |                  |              |                  |
 | kube-apiserver   |              | application Pods |
 | etcd             |              | kube-proxy       |
 | scheduler        |              | calico-node      |
 | controller mgr   |              | containerd       |
 | CoreDNS          |              |                  |
 | Calico           |              |                  |
 +--------+---------+              +---------+--------+
          |                                  |
          +---------- Calico IPIP -----------+
                         |
                  Pod network
                192.168.0.0/16
```

The lab currently uses two OCI Compute instances:

| Node | Role |
|---|---|
| `k8s-cp-01` | Kubernetes control plane |
| `k8s-worker-01` | Kubernetes worker |

Real public/private IP addresses are intentionally not stored in this repository.

---

## Repository structure

```text
k8s-oci-lab/
├── manifests/
│   └── calico-installation.yaml
├── scripts/
│   ├── 00-common.sh
│   ├── 10-control-plane.sh
│   ├── 20-worker.sh
│   └── k8s-host-firewall.sh
└── README.md
```

### Scripts

#### `00-common.sh`

Prepares any Ubuntu node for Kubernetes.

It performs tasks such as:

- installing containerd
- disabling swap
- loading required kernel modules
- enabling IP forwarding
- configuring `br_netfilter`
- configuring containerd with `SystemdCgroup = true`
- installing kubelet, kubeadm and kubectl
- configuring the host firewall
- enabling required Kubernetes and Calico ports

Run this script on **every node**.

---

#### `10-control-plane.sh`

Initializes the Kubernetes control plane.

It:

- detects the private IP address automatically
- validates the installed Kubernetes version
- initializes Kubernetes with `kubeadm`
- configures the local kubeconfig
- creates a worker join command

The Pod network used by this lab is:

```text
192.168.0.0/16
```

---

#### `20-worker.sh`

Safely joins a worker node to the cluster.

Instead of accepting a shell command as a string, it validates the Kubernetes endpoint, token and CA hash independently.

Example:

```bash
sudo ./20-worker.sh \
  <CONTROL_PLANE_PRIVATE_IP>:6443 \
  <TOKEN> \
  sha256:<CA_HASH>
```

Do not store real bootstrap tokens in the repository.

---

#### `k8s-host-firewall.sh`

Configures the host firewall for Kubernetes and Calico.

The OCI Ubuntu image includes a default `FORWARD` rejection rule that prevents Kubernetes Pod traffic from being forwarded.

The script removes that conflicting rule and permits the required internal Kubernetes/Calico traffic.

Among the protocols/ports used by the lab are:

| Protocol / Port | Purpose |
|---|---|
| TCP 6443 | Kubernetes API |
| TCP 10250 | kubelet API |
| TCP 179 | Calico BGP |
| TCP 5473 | Calico Typha |
| IP protocol 4 | Calico IP-in-IP |

The rules are limited to the private OCI subnet where appropriate.

---

# Prerequisites

## OCI

Create two Ubuntu x86_64 VMs inside the same OCI VCN/subnet.

Example topology:

```text
VCN
└── Public subnet
    ├── k8s-cp-01
    └── k8s-worker-01
```

This lab was tested with:

- Ubuntu 24.04 LTS
- OCI `VM.Standard.E4.Flex`
- x86_64
- containerd 2.x
- Kubernetes v1.37

### Important OCI setting

For each Kubernetes VM VNIC, enable:

```text
Skip Source/Destination Check = Yes
```

This is required because the instances route traffic for Kubernetes Pod networks.

---

## OCI network rules

The instances must be able to communicate over their private network.

For a lab environment it is convenient to allow internal traffic between nodes on the Kubernetes subnet.

SSH access should only be allowed from a trusted administration IP.

Do not expose the Kubernetes API or administration interfaces directly to the Internet unless you understand and intentionally configure the security implications.

---

# Installation

## 1. Prepare the control plane

Clone the repository:

```bash
git clone <YOUR_REPOSITORY_URL>
cd k8s-oci-lab
```

Run the common bootstrap:

```bash
sudo ./scripts/00-common.sh
```

Verify:

```bash
containerd --version
kubeadm version
kubelet --version
kubectl version --client
```

Verify the kernel settings:

```bash
sysctl net.ipv4.ip_forward
sysctl net.bridge.bridge-nf-call-iptables
```

Expected:

```text
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
```

Swap should be disabled:

```bash
swapon --show
```

---

## 2. Initialize the control plane

Run:

```bash
./scripts/10-control-plane.sh
```

The script automatically detects the node's private IPv4 address.

After a successful initialization:

```bash
kubectl get nodes
```

The control plane may temporarily show `NotReady` until the CNI plugin is installed.

---

# Install Calico

This lab uses the Tigera Operator and Calico.

Install the operator:

```bash
kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/tigera-operator.yaml
```

Apply the local Calico configuration:

```bash
kubectl apply -f manifests/calico-installation.yaml
```

The important networking setting used by this lab is:

```yaml
calicoNetwork:
  ipPools:
    - cidr: 192.168.0.0/16
      blockSize: 26
      encapsulation: IPIP
      natOutgoing: Enabled
      nodeSelector: all()
```

Wait until Calico is ready:

```bash
kubectl get pods -A
kubectl get tigerastatus
```

The control plane should eventually become:

```text
Ready
```

---

# Join the worker

Run the common bootstrap on the worker:

```bash
sudo ./scripts/00-common.sh
```

On the control plane, generate a fresh join command if required:

```bash
sudo kubeadm token create \
  --kubeconfig /etc/kubernetes/admin.conf \
  --print-join-command
```

Use the endpoint, token and CA hash with:

```bash
sudo ./scripts/20-worker.sh \
  <CONTROL_PLANE_PRIVATE_IP>:6443 \
  <TOKEN> \
  sha256:<CA_HASH>
```

Verify from the control plane:

```bash
kubectl get nodes -o wide
```

Expected:

```text
NAME            STATUS   ROLES
k8s-cp-01       Ready    control-plane
k8s-worker-01   Ready    <none>
```

---

# Cluster validation

The rebuild is considered successful only after validating actual Pod and Service networking.

Create a test workload:

```bash
kubectl create deployment nginx-lab --image=nginx:alpine
kubectl scale deployment nginx-lab --replicas=3
```

Expose it:

```bash
kubectl expose deployment nginx-lab \
  --port=80 \
  --target-port=80 \
  --type=ClusterIP
```

Create a diagnostic Pod:

```bash
kubectl run net-debug \
  --image=busybox:1.36 \
  --restart=Never \
  -- sleep 86400
```

Check scheduling:

```bash
kubectl get pods -o wide
```

---

## Validate DNS

```bash
kubectl exec net-debug -- \
  nslookup nginx-lab.default.svc.cluster.local
```

Expected result:

```text
Name: nginx-lab.default.svc.cluster.local
Address: <CLUSTER_IP>
```

---

## Validate the Service

```bash
kubectl exec net-debug -- \
  wget -qO- http://nginx-lab
```

Expected:

```html
<h1>Welcome to nginx!</h1>
```

---

## Validate cross-node networking

Find the CoreDNS Pods:

```bash
kubectl get pods \
  -n kube-system \
  -l k8s-app=kube-dns \
  -o wide
```

From `net-debug`, ping one of the CoreDNS Pod IP addresses:

```bash
kubectl exec net-debug -- \
  ping -c 3 <COREDNS_POD_IP>
```

Successful communication confirms that Pod traffic can cross nodes through Calico.

---

# Why Calico IPIP?

Initially the lab used:

```text
IPIPCrossSubnet
```

Both OCI nodes were located inside the same `10.0.1.0/24` subnet.

Because Calico considered the nodes to be on the same subnet, cross-node Pod traffic was routed without encapsulation.

This did not work correctly with the OCI underlay configuration used by the lab.

The symptom was:

```text
Pod -> Pod same node       OK
Pod -> Pod different node  FAILED
CoreDNS                    FAILED
```

Switching Calico to:

```text
IPIP
```

caused traffic between Pod networks to be encapsulated between the real OCI node addresses.

After the change:

```text
Pod -> Pod same node       OK
Pod -> Pod different node  OK
CoreDNS                    OK
ClusterIP                  OK
DNS                        OK
```

This was one of the main networking lessons from the lab.

---

# OCI firewall lesson

Ubuntu OCI images include a firewall rule similar to:

```text
FORWARD
REJECT --reject-with icmp-host-prohibited
```

This caused Kubernetes traffic to fail even when Calico had already accepted it.

A packet capture showed the node returning:

```text
ICMP host unreachable - admin prohibited
```

The effective path looked like:

```text
Pod
 |
 v
Calico interface
 |
 v
cali-FORWARD
 |
 v
Calico accepts packet
 |
 v
host FORWARD chain
 |
 X
OCI Ubuntu REJECT
```

The bootstrap script removes the conflicting host `FORWARD` rejection rule.

This is intentionally automated rather than persisting the complete iptables state, because Kubernetes and Calico dynamically manage their own firewall chains.

---

# Headlamp

The cluster can be inspected visually using
[Headlamp](https://headlamp.dev/).

Headlamp provides a useful visual representation of:

- Nodes
- Namespaces
- Deployments
- ReplicaSets
- Pods
- Services
- EndpointSlices
- ConfigMaps
- Secrets metadata
- Events
- Custom Resources

A particularly useful view is the resource map:

```text
Deployment
    |
    v
ReplicaSet
    |
    +---- Pod
    +---- Pod
    +---- Pod
           |
           v
        Service
           |
           v
      EndpointSlice
```

---

## Headlamp access

For this lab, Headlamp is **not exposed publicly**.

It is accessed using `kubectl port-forward` and an SSH tunnel.

Example on the control plane:

```bash
kubectl port-forward \
  -n kube-system \
  svc/headlamp \
  8080:80
```

From the local workstation:

```bash
ssh \
  -L 8080:127.0.0.1:8080 \
  ubuntu@<CONTROL_PLANE_PUBLIC_IP>
```

Then open:

```text
http://localhost:8080
```

This keeps the Headlamp interface off the public Internet.

---

# Security notes

This repository intentionally contains **no credentials**.

Never commit:

```text
OCI private keys
SSH private keys
kubeconfig files
Kubernetes bootstrap tokens
ServiceAccount tokens
cloud credentials
real secrets
private certificates
Terraform state
```

The following values should be provided dynamically:

```text
public IP addresses
private IP addresses
bootstrap tokens
CA hashes
SSH source addresses
```

The scripts are designed to avoid hardcoding instance-specific Kubernetes addresses.

---

# Public repository checklist

Before pushing:

```bash
git grep -Ei \
  'password|secret|token|private.key|BEGIN.*PRIVATE|ocid1|155\.|146\.'
```

Also verify:

```bash
git status
git diff --cached
```

Recommended `.gitignore`:

```gitignore
# Kubernetes
*.kubeconfig
admin.conf

# Keys and certificates
*.pem
*.key
*.crt

# SSH
id_rsa
id_ed25519

# Secrets
.env
.env.*
secrets/
credentials/

# macOS
.DS_Store

# Editors
.vscode/
.idea/

# Temporary files
*.log
*.tmp
```

---

# Rebuild test

One of the goals of this project was to prove that the installation was reproducible.

The original VMs were destroyed and two new clean Ubuntu instances were created.

The cluster was rebuilt using the scripts in this repository.

The final validation produced:

```text
Control plane Ready         PASS
Worker Ready                PASS
Calico                      PASS
CoreDNS                     PASS
Pod-to-Pod same node        PASS
Pod-to-Pod cross-node       PASS
ClusterIP                   PASS
Kubernetes DNS              PASS
HTTP Service                PASS
Headlamp                    PASS
```

---

# Current status

### Completed

- [x] OCI network
- [x] Control plane VM
- [x] Worker VM
- [x] containerd
- [x] Kubernetes v1.37
- [x] kubeadm bootstrap
- [x] Worker join automation
- [x] Host firewall automation
- [x] Calico
- [x] IPIP cross-node networking
- [x] CoreDNS
- [x] ClusterIP Services
- [x] End-to-end workload validation
- [x] Headlamp dashboard
- [x] Clean VM rebuild test

### Future lab stages

- [ ] Automate Calico installation
- [ ] Ingress NGINX
- [ ] Ingress routing by host/path
- [ ] metrics-server
- [ ] Prometheus
- [ ] Grafana
- [ ] Persistent Volumes
- [ ] NetworkPolicies
- [ ] Additional worker nodes
- [ ] Upgrade exercises
- [ ] Failure and recovery scenarios

---

# Disclaimer

This project is a learning environment.

It is **not intended to represent a production-ready Kubernetes architecture**.

Several decisions are intentionally simplified to make Kubernetes networking, bootstrap and troubleshooting easier to understand.

---

## Main takeaway

The most valuable part of this lab was not getting two nodes to show `Ready`.

It was understanding the complete path behind that result:

```text
OCI networking
     ↓
Linux networking
     ↓
container runtime
     ↓
kubelet
     ↓
kubeadm
     ↓
control plane
     ↓
Calico
     ↓
Pod networking
     ↓
CoreDNS
     ↓
Services
     ↓
workloads
```

The cluster can now be destroyed, recreated and validated from clean virtual machines using a repeatable process.