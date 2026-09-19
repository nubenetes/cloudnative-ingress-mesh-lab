[🏠 Home / README](../README.md) | [Architecture](ARCHITECTURE.md) | [FQDN Routing](FQDN_ROUTING.md) | [Lab 1: Cilium](LAB_CILIUM.md) | [Lab 2: Istio Ambient](LAB_ISTIO_AMBIENT.md) | **Lab 3: Traefik Edge**

---

# Lab 3: Gateway API-Native Edge Router (Traefik v3)

This laboratory provides an end-to-end, production-grade guide for deploying and operating **Traefik v3** as a high-performance, Kubernetes Gateway API-native edge ingress controller with advanced middleware filters.

---

## Table of Contents
- [1. Architectural Prerequisites](#1-architectural-prerequisites)
- [2. Cluster Topology & Kind Configuration](#2-cluster-topology--kind-configuration)
- [3. Gateway API CRD Installation](#3-gateway-api-crd-installation)
- [4. Traefik v3 Deployment with Gateway API Provider](#4-traefik-v3-deployment-with-gateway-api-provider)
- [5. Gateway API Infrastructure Manifests](#5-gateway-api-infrastructure-manifests)
  - [5.1 GatewayClass & Gateway](#51-gatewayclass--gateway)
  - [5.2 Traefik Advanced Middlewares](#52-traefik-advanced-middlewares)
  - [5.3 90/10 Canary Shifting with Middleware Filters](#53-9010-canary-shifting-with-middleware-filters)
- [6. Real-World Testing & Verification](#6-real-world-testing--verification)
  - [6.1 Canary Verification Script](#61-canary-verification-script)
  - [6.2 Security Headers & Response Inspection](#62-security-headers--response-inspection)
  - [6.3 Rate Limiting Stress Test](#63-rate-limiting-stress-test)
  - [6.4 Live Prometheus Metrics Inspection](#64-live-prometheus-metrics-inspection)
- [7. References & Authoritative Sources of Truth](#7-references--authoritative-sources-of-truth)

---

## 1. Architectural Prerequisites

- **Kubernetes Version**: v1.28.0+ (Tested against v1.30.2)
- **Required API Groups**:
  - `gateway.networking.k8s.io/v1` (`GatewayClass`, `Gateway`, `HTTPRoute`)
  - `traefik.io/v1alpha1` (`Middleware`, `IngressRoute`)
- **Traefik Version**: v3.1.0+ (Full native support for Gateway API v1)

---

## 2. Cluster Topology & Kind Configuration

Create a Kind cluster exposing host ports 80 and 443:

```yaml
# kind-traefik.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
```

Provision the cluster:
```bash
kind create cluster --name lab-traefik --config kind-traefik.yaml
```

---

## 3. Gateway API CRD Installation

Install the standard Kubernetes Gateway API v1 CRDs:
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

---

## 4. Traefik v3 Deployment with Gateway API Provider

Deploy Traefik v3 using Helm with the native Gateway API provider enabled:

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

helm upgrade --install traefik traefik/traefik \
  --version 31.0.0 \
  --namespace traefik-system \
  --create-namespace \
  --set "providers.kubernetesGateway.enabled=true" \
  --set "experimental.kubernetesGateway.enabled=true" \
  --set "ports.web.port=8000" \
  --set "ports.web.exposedPort=80" \
  --set "ports.web.nodePort=80" \
  --set "ports.websecure.port=8443" \
  --set "ports.websecure.exposedPort=443" \
  --set "ports.websecure.nodePort=443" \
  --set "service.type=NodePort" \
  --set "metrics.prometheus.enabled=true" \
  --set "metrics.prometheus.entryPoint=metrics" \
  --set "ingressClass.enabled=false" \
  --wait
```

Verify the Traefik deployment:
```bash
kubectl get pods -n traefik-system
```

---

## 5. Gateway API Infrastructure Manifests

Create the workload namespace:
```bash
kubectl create namespace lab-traefik
```

### 5.1 GatewayClass & Gateway

Define the GatewayClass and Gateway resources:

```yaml
# deploys/traefik/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: traefik
spec:
  controllerName: traefik.io/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: traefik-edge-gw
  namespace: lab-traefik
spec:
  gatewayClassName: traefik
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

### 5.2 Traefik Advanced Middlewares

Provision production-grade middleware filters:
- **RateLimiting**: Token bucket algorithm (Average 10 req/s, Burst 15)
- **SecurityHeaders**: Custom response headers (HSTS, frame options, XSS protection)
- **CircuitBreaker**: Trips when latency exceeds 200ms or error rate exceeds 20%

```yaml
# deploys/traefik/middlewares.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: edge-rate-limit
  namespace: lab-traefik
spec:
  rateLimit:
    average: 10
    burst: 15
    period: 1s
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: lab-traefik
spec:
  headers:
    customResponseHeaders:
      X-Frame-Options: "DENY"
      X-Content-Type-Options: "nosniff"
      X-XSS-Protection: "1; mode=block"
      X-Engineered-By: "Traefik-v3-Gateway-API"
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: edge-circuit-breaker
  namespace: lab-traefik
spec:
  circuitBreaker:
    expression: "LatencyAtQuantileMS(50.0) > 200 || NetworkErrorRatio() > 0.20"
```

### 5.3 90/10 Canary Shifting with Middleware Filters

Attach the middlewares and configure the 90/10 traffic split in the `HTTPRoute`:

```yaml
# deploys/traefik/httproute-canary.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: traefik-backend-route
  namespace: lab-traefik
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: "lab-traefik-edge-rate-limit@kubernetescrd,lab-traefik-security-headers@kubernetescrd"
spec:
  parentRefs:
    - name: traefik-edge-gw
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

Apply all manifests:
```bash
kubectl apply -f deploys/common/backend-v1.yaml -n lab-traefik
kubectl apply -f deploys/common/backend-v2.yaml -n lab-traefik
kubectl apply -f deploys/traefik/gateway.yaml
kubectl apply -f deploys/traefik/middlewares.yaml
kubectl apply -f deploys/traefik/httproute-canary.yaml
```

---

## 6. Real-World Testing & Verification

### 6.1 Canary Verification Script

Run 100 sequential requests to measure the 90/10 split:

```bash
echo "=== Testing 90/10 Canary Split via Traefik v3 Edge Gateway ==="
V1_TOTAL=0
V2_TOTAL=0

for i in {1..100}; do
  OUTPUT=$(curl -s "http://127.0.0.1/api/info" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
  if [[ "$OUTPUT" == *"v1"* ]]; then
    ((V1_TOTAL++))
  elif [[ "$OUTPUT" == *"v2"* ]]; then
    ((V2_TOTAL++))
  fi
done

echo "Traffic Split Distribution:"
echo "Backend v1 (90% target): ${V1_TOTAL}%"
echo "Backend v2 (10% target): ${V2_TOTAL}%"
```

### 6.2 Security Headers & Response Inspection

Verify that the `security-headers` middleware injected headers:

```bash
echo "=== Inspecting Injected Security Headers ==="
curl -s -I "http://127.0.0.1/api/info" | grep -E "X-Engineered-By|X-Frame-Options|X-Content-Type-Options"
```
*Expected Output:*
```http
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
X-Engineered-By: Traefik-v3-Gateway-API
```

### 6.3 Rate Limiting Stress Test

Flood the endpoint to trigger the token-bucket rate limiter:

```bash
echo "=== Stress Testing Rate Limiter (Target: HTTP 429) ==="
SUCCESS=0
RATELIMITED=0

for i in {1..35}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1/api/info")
  if [[ "$CODE" == "200" ]]; then
    ((SUCCESS++))
  elif [[ "$CODE" == "429" ]]; then
    ((RATELIMITED++))
  fi
done

echo "Successful Requests (200 OK): ${SUCCESS}"
echo "Throttled Requests (429 Too Many Requests): ${RATELIMITED}"
```

### 6.4 Live Prometheus Metrics Inspection

# Inspect Traefik's internal Prometheus metrics:
```bash
kubectl exec -n traefik-system deploy/traefik -- wget -qO- http://localhost:9100/metrics | grep "traefik_service_request_duration_seconds" | head -n 15
```

---

## 7. References & Authoritative Sources of Truth

- **Traefik v3 Official Documentation: Kubernetes Gateway Provider**: [https://doc.traefik.io/traefik/providers/kubernetes-gateway/](https://doc.traefik.io/traefik/providers/kubernetes-gateway/)  
  *Upstream technical reference for configuring GatewayClass, Gateway listeners, HTTPRoutes, and extension filters.*
- **Traefik Middlewares Overview & Configuration Reference**: [https://doc.traefik.io/traefik/middlewares/overview/](https://doc.traefik.io/traefik/middlewares/overview/)  
  *Detailed specification for RateLimit (token bucket), CircuitBreaker, Custom Request/Response Headers, and ForwardAuth.*
- **Traefik Official Helm Chart Documentation**: [https://github.com/traefik/traefik-helm-chart](https://github.com/traefik/traefik-helm-chart)  
  *Source of truth for Helm deployment parameters, experimental Gateway API flags, and service port definitions.*
- **Traefik Observability: Prometheus Metrics Exposition**: [https://doc.traefik.io/traefik/observability/metrics/prometheus/](https://doc.traefik.io/traefik/observability/metrics/prometheus/)  
  *Metrics schema for request durations, status code counts, and latency histogram buckets.*
- **Red Hat OpenShift SecurityContextConstraints (SCCs) Reference**: [https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)  
  *Guidelines for granting appropriate execution permissions to edge ingress proxies on OpenShift clusters.*

---

⬅️ Previous: [Lab 2: Istio Ambient](LAB_ISTIO_AMBIENT.md) | 🏠 [Home](../README.md) | 🔄 Reset: [Lab 1: Cilium eBPF](LAB_CILIUM.md)
