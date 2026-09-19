[🏠 Home / README](../README.md) | [Architecture](ARCHITECTURE.md) | [FQDN Routing](FQDN_ROUTING.md) | [Lab 1: Cilium](LAB_CILIUM.md) | **Lab 2: Istio Ambient** | [Lab 3: Traefik Edge](LAB_TRAEFIK_EDGE.md)

---

# Lab 2: Sidecarless Service Mesh (Istio Ambient Mode)

This laboratory provides an end-to-end, production-grade guide for deploying and testing **Istio Ambient Mode** using node-level L4 **ztunnel** and namespace-level L7 **Waypoint Proxies** managed via the Kubernetes Gateway API.

---

## Table of Contents
- [1. Architectural Prerequisites](#1-architectural-prerequisites)
- [2. Cluster Topology & Kind Configuration](#2-cluster-topology--kind-configuration)
- [3. Gateway API Experimental CRD Installation](#3-gateway-api-experimental-crd-installation)
- [4. Istio Ambient Installation](#4-istio-ambient-installation)
- [5. Workload Onboarding & Namespace Enrollment](#5-workload-onboarding--namespace-enrollment)
- [6. L4 Zero-Trust Transport & Cryptographic Validation](#6-l4-zero-trust-transport--cryptographic-validation)
  - [6.1 Strict mTLS Enforcement](#61-strict-mtls-enforcement)
  - [6.2 L4 Layer Authorization Policy](#62-l4-layer-authorization-policy)
- [7. L7 Waypoint Proxy & 90/10 Canary Shifting](#7-l7-waypoint-proxy--9010-canary-shifting)
  - [7.1 North-South Ingress Gateway](#71-north-south-ingress-gateway)
  - [7.2 90/10 Canary HTTPRoute](#72-9010-canary-httproute)
- [8. Real-World Testing & Verification](#8-real-world-testing--verification)
  - [8.1 Automated Canary Verification Script](#81-automated-canary-verification-script)
  - [8.2 Cryptographic Zero-Trust Validation from Attacker Pod](#82-cryptographic-zero-trust-validation-from-attacker-pod)
  - [8.3 Live Data Plane Diagnostics](#83-live-data-plane-diagnostics)

---

## 1. Architectural Prerequisites

- **Kubernetes Version**: v1.28.0+ (Tested against v1.30.2)
- **Linux Kernel**: >= 5.4 (Supports Geneve encapsulation and modern tproxy/redirect iptables)
- **Required API Groups**:
  - `gateway.networking.k8s.io/v1` (`GatewayClass`, `Gateway`, `HTTPRoute`)
  - `security.istio.io/v1` (`AuthorizationPolicy`, `PeerAuthentication`)
- **Gateway API Channel**: **Experimental** (Required for `istio-waypoint` GatewayClass support)

---

## 2. Cluster Topology & Kind Configuration

Create a multi-node Kind cluster exposing ports 80 and 443 for edge ingress:

```yaml
# kind-istio.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 80
        protocol: TCP
      - containerPort: 30443
        hostPort: 443
        protocol: TCP
  - role: worker
  - role: worker
```

Provision the cluster:
```bash
kind create cluster --name lab-istio --config kind-istio.yaml
```

---

## 3. Gateway API Experimental CRD Installation

Istio Ambient requires the experimental Gateway API CRDs to support waypoint proxies:
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/experimental-install.yaml
```

Verify CRD readiness:
```bash
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
```

---

## 4. Istio Ambient Installation

Deploy the Istio Ambient control plane and `ztunnel` daemonset using Helm:

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# 1. Base CRDs
helm upgrade --install istio-base istio/base \
  -n istio-system \
  --create-namespace

# 2. Istio Control Plane (istiod) with Ambient profile
helm upgrade --install istiod istio/istiod \
  -n istio-system \
  --set profile=ambient \
  --set pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true \
  --wait

# 3. Node-Level L4 Data Plane (ztunnel DaemonSet)
helm upgrade --install ztunnel istio/ztunnel \
  -n istio-system \
  --wait

# 4. Istio CNI (Manages traffic redirection to ztunnel)
helm upgrade --install istio-cni istio/cni \
  -n istio-system \
  --set profile=ambient \
  --wait
```

Verify ambient infrastructure:
```bash
kubectl get daemonset -n istio-system ztunnel
kubectl get pods -n istio-system
```

---

## 5. Workload Onboarding & Namespace Enrollment

Enroll application workloads into the ambient mesh without modifying pod definitions or restarting containers:

```bash
kubectl create namespace lab-istio
kubectl create namespace attacker

# Label namespace for Ambient data plane enrollment
kubectl label namespace lab-istio istio.io/dataplane-mode=ambient
```

Deploy the microservices (Backend v1, Backend v2, Frontend):
```bash
kubectl apply -f deploys/common/backend-v1.yaml -n lab-istio
kubectl apply -f deploys/common/backend-v2.yaml -n lab-istio
kubectl apply -f deploys/common/frontend.yaml -n lab-istio
```

*Note: Notice that no sidecar containers (`istio-proxy`) are injected. Application pods run exactly 1/1 containers.*

---

## 6. L4 Zero-Trust Transport & Cryptographic Validation

All pod-to-pod traffic within `lab-istio` is now automatically secured with mutual TLS via HBONE (port 15008).

### 6.1 Strict mTLS Enforcement

Enforce strict mTLS across the namespace:
```yaml
# deploys/istio/peer-auth.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: lab-istio
spec:
  mtls:
    mode: STRICT
```

Apply the policy:
```bash
kubectl apply -f deploys/istio/peer-auth.yaml
```

### 6.2 L4 Layer Authorization Policy

Enforce that backend pods only accept traffic bearing valid cryptographic SPIFFE identities:

```yaml
# deploys/istio/authorization-policy.yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: backend-l4-policy
  namespace: lab-istio
spec:
  selector:
    matchLabels:
      app: backend
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/lab-istio/sa/frontend-sa"]
```

---

## 7. L7 Waypoint Proxy & 90/10 Canary Shifting

When Layer 7 policies (header matching, canary splitting) are required, instantiate a dedicated Waypoint Proxy:

```yaml
# deploys/istio/waypoint-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: backend-waypoint
  namespace: lab-istio
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
```

Apply the waypoint proxy:
```bash
kubectl apply -f deploys/istio/waypoint-gateway.yaml
kubectl rollout status deployment/backend-waypoint -n lab-istio
```

### 7.1 North-South Ingress Gateway

Provision the North-South edge entry point:

```yaml
# deploys/istio/ingress-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-ingress
  namespace: lab-istio
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
```

### 7.2 90/10 Canary HTTPRoute

Direct ingress traffic through the Waypoint proxy to execute a 90/10 canary split:

```yaml
# deploys/istio/httproute-canary.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backend-canary
  namespace: lab-istio
spec:
  parentRefs:
    - name: istio-ingress
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

Apply manifests:
```bash
kubectl apply -f deploys/istio/ingress-gateway.yaml
kubectl apply -f deploys/istio/httproute-canary.yaml
```

---

## 8. Real-World Testing & Verification

### 8.1 Automated Canary Verification Script

```bash
GW_IP="127.0.0.1"
echo "=== Running 100 Canary Requests via Istio Ambient Ingress ==="

V1_HITS=0
V2_HITS=0

for i in {1..100}; do
  RESP=$(curl -s -H "Host: backend.lab-istio.example.com" "http://${GW_IP}/api/info" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
  if [[ "$RESP" == *"v1"* ]]; then
    ((V1_HITS++))
  elif [[ "$RESP" == *"v2"* ]]; then
    ((V2_HITS++))
  fi
done

echo "Traffic Split Results:"
echo "Backend v1 (90% Weight): ${V1_HITS}%"
echo "Backend v2 (10% Weight): ${V2_HITS}%"
```

### 8.2 Cryptographic Zero-Trust Validation from Attacker Pod

Deploy an unmeshed rogue pod outside the ambient mesh:
```bash
kubectl run rogue-pod --namespace=attacker --image=curlimages/curl:8.7.1 -- sleep 3600
```

Execute an unauthorized probe against the backend:
```bash
echo "=== Testing Direct Ingress from Unauthenticated Pod ==="
kubectl exec -n attacker rogue-pod -- curl -m 3 -s -i "http://backend-v1.lab-istio.svc.cluster.local:8080/api/info" || echo "BLOCKED: Connection reset / dropped by ztunnel mTLS enforcement"
```
*Expected Result:* Connection terminates with `Empty reply from server` or `Connection reset by peer` because ztunnel strictly enforces HBONE TLS handshake verification.

### 8.3 Live Data Plane Diagnostics

Inspect the internal ztunnel connection pool and active certificates:
```bash
# List active ztunnel L4 connections
istioctl ztunnel-config connections

# Inspect active workload certificates and SPIFFE SANs
istioctl ztunnel-config certificates

# Verify waypoint proxy routes
istioctl proxy-config routes deploy/backend-waypoint.lab-istio
```

---

⬅️ Previous: [Lab 1: Cilium eBPF](LAB_CILIUM.md) | 🏠 [Home](../README.md) | ➡️ Next: [Lab 3: Traefik Edge Router](LAB_TRAEFIK_EDGE.md)
