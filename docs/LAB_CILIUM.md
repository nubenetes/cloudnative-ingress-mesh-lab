[🏠 Home / README](../README.md) | [Architecture](ARCHITECTURE.md) | [FQDN Routing](FQDN_ROUTING.md) | **Lab 1: Cilium** | [Lab 2: Istio Ambient](LAB_ISTIO_AMBIENT.md) | [Lab 3: Traefik Edge](LAB_TRAEFIK_EDGE.md)

---

# Lab 1: Kernel-Level eBPF Gateway & Service Mesh (Cilium)

This laboratory provides an end-to-end, production-grade guide for deploying and testing **Cilium Service Mesh and Gateway API** in a sidecarless, eBPF-accelerated environment.

---

## Table of Contents
- [1. Architectural Prerequisites](#1-architectural-prerequisites)
- [2. Cluster Topology & Kind Configuration](#2-cluster-topology--kind-configuration)
- [3. Gateway API CRD Installation](#3-gateway-api-crd-installation)
- [4. Cilium Deployment with Gateway API & Hubble](#4-cilium-deployment-with-gateway-api--hubble)
- [5. Workload & Gateway API Manifests](#5-workload--gateway-api-manifests)
  - [5.1 GatewayClass & Gateway Configuration](#51-gatewayclass--gateway-configuration)
  - [5.2 Microservice Workloads (v1 & v2 Canary)](#52-microservice-workloads-v1--v2-canary)
  - [5.3 90/10 Canary Traffic Shifting via HTTPRoute](#53-9010-canary-traffic-shifting-via-httproute)
- [6. L7 Security Policy & Zero-Trust Verification](#6-l7-security-policy--zero-trust-verification)
- [7. Real-World Testing & Verification Scripts](#7-real-world-testing--verification-scripts)
  - [7.1 Automated Canary Traffic-Split Test](#71-automated-canary-traffic-split-test)
  - [7.2 Cryptographic Security & Zero-Trust Validation](#72-cryptographic-security--zero-trust-validation)
  - [7.3 Live eBPF & Hubble Observability](#73-live-ebpf--hubble-observability)

---

## 1. Architectural Prerequisites

- **Kubernetes Version**: v1.28.0+ (Tested against v1.30.2)
- **Linux Kernel**: >= 5.10 (Requires `CONFIG_BPF=y`, `CONFIG_BPF_SYSCALL=y`, `CONFIG_NET_CLS_ACT=y`, `CONFIG_CGROUP_BPF=y`)
- **Host Subsystems**:
  - Mounted BPF filesystem at `/sys/fs/bpf` (shared mount propagation)
  - cgroup v2 hierarchy at `/sys/fs/cgroup`
- **Required API Groups**:
  - `gateway.networking.k8s.io/v1` (`GatewayClass`, `Gateway`, `HTTPRoute`)
  - `cilium.io/v2` (`CiliumNetworkPolicy`, `CiliumClusterwideNetworkPolicy`)

---

## 2. Cluster Topology & Kind Configuration

To allow Cilium to manage low-level node networking without conflicting with default CNI plugins, bootstrap a Kind cluster with default CNI disabled and `/sys/fs/bpf` mounted:

```yaml
# kind-cilium.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /sys/fs/bpf
        containerPath: /sys/fs/bpf
        propagation: Bidirectional
  - role: worker
    extraMounts:
      - hostPath: /sys/fs/bpf
        containerPath: /sys/fs/bpf
        propagation: Bidirectional
networking:
  disableDefaultCNI: true
  kubeProxyMode: "none"
```

Provision the cluster:
```bash
kind create cluster --name lab-cilium --config kind-cilium.yaml
```

---

## 3. Gateway API CRD Installation

Install the official Kubernetes Gateway API standard CRDs:
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

Verify CRD readiness:
```bash
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io
```

---

## 4. Cilium Deployment with Gateway API & Hubble

Deploy Cilium using Helm with native eBPF host routing, kube-proxy replacement, Gateway API controller, and Hubble observability enabled:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade --install cilium cilium/cilium \
  --version 1.16.0 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=lab-cilium-control-plane \
  --set k8sServicePort=6443 \
  --set gatewayAPI.enabled=true \
  --set socketLB.enabled=true \
  --set socketLB.hostNamespaceOnly=false \
  --set bpf.masquerade=true \
  --set loadBalancer.l7.backend=envoy \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set authentication.mutual.spire.enabled=true \
  --set authentication.mutual.spire.install.enabled=true
```

Wait for Cilium pods to be fully operational:
```bash
kubectl -n kube-system rollout status ds/cilium --timeout=180s
cilium status --wait
```

---

## 5. Workload & Gateway API Manifests

Create the dedicated workload namespace and deploy sample microservices:

```bash
kubectl create namespace lab-cilium
kubectl create namespace attacker
```

### 5.1 GatewayClass & Gateway Configuration

Cilium automatically registers the `cilium` `GatewayClass`. Deploy the Gateway instance:

```yaml
# deploys/cilium/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cilium-gw
  namespace: lab-cilium
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

### 5.2 Microservice Workloads (v1 & v2 Canary)

Deploy the backend deployments:
- **Backend v1**: Primary stable workload (90% target)
- **Backend v2**: Canary workload (10% target)

```yaml
# deploys/common/backend-v1.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-v1
  namespace: lab-cilium
  labels:
    app: backend
    version: v1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
      version: v1
  template:
    metadata:
      labels:
        app: backend
        version: v1
    spec:
      containers:
        - name: app
          image: quay.io/openshift-examples/api-app:latest
          env:
            - name: APP_VERSION
              value: "v1-production"
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: backend-v1
  namespace: lab-cilium
spec:
  ports:
    - port: 8080
      targetPort: 8080
      name: http
  selector:
    app: backend
    version: v1
```

```yaml
# deploys/common/backend-v2.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-v2
  namespace: lab-cilium
  labels:
    app: backend
    version: v2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
      version: v2
  template:
    metadata:
      labels:
        app: backend
        version: v2
    spec:
      containers:
        - name: app
          image: quay.io/openshift-examples/api-app:latest
          env:
            - name: APP_VERSION
              value: "v2-canary"
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: backend-v2
  namespace: lab-cilium
spec:
  ports:
    - port: 8080
      targetPort: 8080
      name: http
  selector:
    app: backend
    version: v2
```

### 5.3 90/10 Canary Traffic Shifting via HTTPRoute

Define the `HTTPRoute` binding to `cilium-gw` with weighted backends:

```yaml
# deploys/cilium/httproute-canary.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backend-canary-route
  namespace: lab-cilium
spec:
  parentRefs:
    - name: cilium-gw
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: backend-v1
          port: 8080
          weight: 90
        - name: backend-v2
          port: 8080
          weight: 10
```

Apply the manifests:
```bash
kubectl apply -f deploys/cilium/gateway.yaml
kubectl apply -f deploys/common/backend-v1.yaml
kubectl apply -f deploys/common/backend-v2.yaml
kubectl apply -f deploys/cilium/httproute-canary.yaml
```

---

## 6. L7 Security Policy & Zero-Trust Verification

Enforce kernel-level Layer 7 inspection and mutual authentication using `CiliumClusterwideNetworkPolicy`.

```yaml
# deploys/cilium/cilium-clusterwide-policy.yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: secure-backend-zero-trust
spec:
  endpointSelector:
    matchLabels:
      app: backend
      io.kubernetes.pod.namespace: lab-cilium
  ingress:
    # Rule 1: Allow Ingress from Cilium Gateway with mutual authentication
    - fromEndpoints:
        - matchLabels:
            io.cilium.k8s.policy.serviceaccount: cilium-gw
      authentication:
        mode: required
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "^/api.*$"
```

Deploy a rogue client inside the `attacker` namespace to validate policy enforcement:
```bash
kubectl run attacker-pod --namespace=attacker --image=curlimages/curl:8.7.1 -- sleep 3600
```

---

## 7. Real-World Testing & Verification Scripts

### 7.1 Automated Canary Traffic-Split Test

Extract the Gateway IP and run an automated 100-request loop to statistically verify the 90/10 distribution:

```bash
GW_IP=$(kubectl get gateway cilium-gw -n lab-cilium -o jsonpath='{.status.addresses[0].value}')

echo "=== Executing 100 Requests to http://${GW_IP}/api/info ==="
V1_COUNT=0
V2_COUNT=0

for i in $(seq 1 100); do
  RESP=$(curl -s "http://${GW_IP}/api/info" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
  if [[ "$RESP" == *"v1"* ]]; then
    ((V1_COUNT++))
  elif [[ "$RESP" == *"v2"* ]]; then
    ((V2_COUNT++))
  fi
done

echo "Traffic Split Results:"
echo "Backend v1 (Target 90%): ${V1_COUNT}%"
echo "Backend v2 (Target 10%): ${V2_COUNT}%"
```

### 7.2 Cryptographic Security & Zero-Trust Validation

Test access from the rogue container:
```bash
echo "=== Testing Unauthorized Ingress from Attacker Pod ==="
kubectl exec -n attacker attacker-pod -- curl -m 3 -s -i "http://backend-v1.lab-cilium.svc.cluster.local:8080/api/info" || echo "SUCCESS: Traffic correctly dropped by Cilium eBPF L7 Policy"
```
*Expected Output:* The connection hangs and times out or returns `Connection refused` directly at the eBPF layer without reaching the application socket.

### 7.3 Live eBPF & Hubble Observability

Inspect real-time socket-level packet decisions:
```bash
# Observe L7 flow verdicts with Hubble CLI
hubble observe --namespace lab-cilium --follow

# View drop reasons across the cluster
hubble observe --verdict DROPPED --follow
```

---

⬅️ Previous: [FQDN-Driven Routing](FQDN_ROUTING.md) | 🏠 [Home](../README.md) | ➡️ Next: [Lab 2: Istio Ambient](LAB_ISTIO_AMBIENT.md)
