# FQDN-Driven Routing: North-South & East-West Architecture Guide

In enterprise cloud-native fabrics, relying solely on Kubernetes internal short-names (`service` or `service.namespace.svc.cluster.local`) introduces significant architectural debt. This guide details why modern platforms enforce **Fully Qualified Domain Names (FQDNs)** across both North-South and East-West transit, and demonstrates production implementations across **Traefik v3 (without a service mesh)**, **Cilium eBPF**, and **Istio Ambient**.

---

## 1. Why Enforce FQDNs on Both North-South and East-West?

### 1.1 The Pitfalls of `service.namespace.svc.cluster.local`
- **Environment & Cluster Lock-in**: Hardcoding `.svc.cluster.local` couples applications directly to Kubernetes internals and specific namespace naming conventions. When splitting services across multi-cluster environments, hybrid clouds, or OpenShift clusters, client configurations break.
- **PKI & Certificate Incompatibility**: Enterprise Certificate Authorities (corporate Vault, Venafi, DigiCert) issue X.509 SAN certificates for organizational domain hierarchies (e.g., `*.services.enterprise.internal` or `api.payments.corp`). Generating corporate-signed TLS certificates for `.svc.cluster.local` violates enterprise security baselines and security audits.
- **Inability to Leverage Centralized Edge Policies for Internal Calls**: Teams needing rate-limiting, circuit breakers, header enrichment, or WAF inspection on internal East-West calls often do not want the operational complexity of a full service mesh. Using an edge gateway like Traefik as an **Internal Ingress Router** allows applying edge middlewares to internal traffic.

---

### 1.2 Enterprise Use Cases

| Use Case | Scenario | Architectural Benefit |
| :--- | :--- | :--- |
| **Unified Internal API Gateway** | Microservice A calls `billing.corp.internal` instead of `billing.finance.svc.cluster.local`. | Requests route through Traefik v3 where token-bucket rate-limiting, JWT authentication, and circuit breaking are applied without deploying a full service mesh. |
| **Hybrid Cloud / Strangler Fig Migration** | `legacy-monolith.corp.internal` resides in on-prem OpenStack/bare-metal; parts are migrated to K8s. | The FQDN initially resolves to an external load balancer. As services are containerized, internal DNS or mesh routing rewires the FQDN to Kubernetes workloads without modifying client code. |
| **Enterprise End-to-End mTLS** | Compliance mandates TLS 1.3 with corporate SANs matching `*.payments.enterprise.net`. | Workloads validate standard FQDN certificates against corporate Root CAs rather than ephemeral, cluster-scoped self-signed CAs. |
| **Dynamic Egress Firewalling** | Pods need access to internal APIs and external SaaS (`api.stripe.com`, `auth.okta.com`). | Cilium eBPF dynamically snoops DNS queries and updates in-kernel IP sets to enforce strict L7 FQDN egress whitelisting. |

---

## 2. Solution Implementation 1: Traefik v3 (without Traefik Mesh)

To use Traefik as an **Internal Edge Router** for East-West FQDN traffic alongside North-South ingress, configure **CoreDNS Split-Horizon / DNS Rewrite** so internal FQDN queries resolve to the internal Traefik Service.

```
[ Workload Pod ] 
       │ 
       │ 1. Resolves `backend.internal.corp` via CoreDNS (rewritten to Traefik ClusterIP)
       ▼
[ Traefik v3 Internal Router ]
       │ 
       │ 2. Evaluates `IngressRoute` matching `Host(`backend.internal.corp`)`
       │ 3. Applies Middlewares: RateLimit + SecurityHeaders + CircuitBreaker
       ▼
[ Target Service: backend-v1:8080 ]
```

### 2.1 CoreDNS In-Cluster Rewrite
Add a rewrite rule to the CoreDNS `Corefile` (in `kube-system/coredns`):

```corefile
.:53 {
    errors
    health
    # Rewrite internal corporate FQDNs to Traefik internal service ClusterIP
    rewrite name regex (.*)\.internal\.corp traefik.traefik-system.svc.cluster.local answer auto
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
```

### 2.2 Traefik `IngressRoute` with Middlewares for East-West & North-South

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: internal-backend-fqdn-route
  namespace: lab-traefik
spec:
  entryPoints:
    - web        # Port 8000 (Internal East-West)
    - websecure   # Port 8443 (North-South Edge)
  routes:
    # Rule: Match on FQDN for both internal pods and external clients
    - match: Host(`backend.internal.corp`) && PathPrefix(`/api`)
      kind: Rule
      services:
        - name: backend-v1
          port: 8080
          weight: 90
        - name: backend-v2
          port: 8080
          weight: 10
      middlewares:
        - name: edge-rate-limit
        - name: security-headers
        - name: internal-auth-forward
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: internal-auth-forward
  namespace: lab-traefik
spec:
  forwardAuth:
    address: "http://auth-service.lab-traefik.svc.cluster.local:9000/verify"
    trustForwardHeader: true
    authResponseHeaders:
      - "X-User-Identity"
      - "X-User-Roles"
```

---

## 3. Solution Implementation 2: Cilium eBPF

Cilium provides two native mechanisms for FQDN routing:
1. **L7 Ingress/East-West Gateway API**: Exposing `HTTPRoute` matching internal and external FQDN hostnames with socket-layer short-circuiting.
2. **DNS-Aware L7 Egress Policies (`toFQDNs`)**: Transparently snooping DNS responses at the kernel level and dynamically populating BPF ipset maps.

### 3.1 Gateway API HTTPRoute Matching Internal & External FQDNs

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: fqdn-multi-plane-route
  namespace: lab-cilium
spec:
  parentRefs:
    - name: cilium-gw
      sectionName: http
  hostnames:
    - "api.nubenetes.io"          # North-South Public Entry
    - "backend.internal.corp"     # East-West Internal Transit
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: backend-v1
          port: 8080
```

### 3.2 Cilium DNS-Aware Egress Policy (`toFQDNs`)

Enforces that pods can only communicate with approved external and internal FQDNs:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: egress-fqdn-firewall
  namespace: lab-cilium
spec:
  endpointSelector:
    matchLabels:
      app: backend
  egress:
    # 1. Allow DNS queries to CoreDNS so Cilium can intercept responses
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
    # 2. Allow egress only to specified internal & external FQDNs
    - toFQDNs:
        - matchName: "api.payments.internal.corp"
        - matchPattern: "*.stripe.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
            - port: "8080"
              protocol: TCP
```

---

## 4. Solution Implementation 3: Istio Ambient Mode

In Istio Ambient, DNS proxying is built into the node-level **ztunnel** daemonset (`ISTIO_META_DNS_CAPTURE=true`). When an internal pod requests `backend.internal.corp`, ztunnel captures the request and maps it to an **Istio `ServiceEntry`** or Gateway API route.

### 4.1 Istio ServiceEntry for Internal FQDN

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: internal-fqdn-service
  namespace: lab-istio
spec:
  hosts:
    - backend.internal.corp
  addresses:
    - 240.240.0.100 # Virtual VIP allocated by Istio DNS capture
  ports:
    - number: 8080
      name: http-api
      protocol: HTTP
  resolution: STATIC
  endpoints:
    - address: backend-v1.lab-istio.svc.cluster.local
      ports:
        http-api: 8080
      labels:
        version: v1
```

### 4.2 Gateway API HTTPRoute Binding to Waypoint with FQDN Hostname

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: waypoint-fqdn-route
  namespace: lab-istio
spec:
  parentRefs:
    - name: backend-waypoint
      sectionName: mesh
  hostnames:
    - "backend.internal.corp"
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

---

## 5. Summary Architectural Comparison

| Dimension | Traefik v3 (No Mesh) | Cilium eBPF | Istio Ambient |
| :--- | :--- | :--- | :--- |
| **DNS Resolution Layer** | CoreDNS rewrite to Traefik ClusterIP | Kernel eBPF DNS proxy intercepts queries directly | ztunnel node-level DNS capture (`ISTIO_META_DNS_CAPTURE`) |
| **Interception Mechanism** | Reverse proxy at Layer 7 (`IngressRoute`) | eBPF socket table (`sock_ops`) & IP set matching | L4 `ztunnel` Geneve/tproxy redirect to `waypoint` |
| **Proxy Traversal** | 1 hop through Traefik | 0 hops (L4) or 1 hop (L7 Envoy redirect) | 1 hop (`ztunnel` L4) + optional Waypoint (L7) |
| **Middlewares / Policies** | Native Traefik Middlewares (RateLimit, Headers) | Cilium L7 Network Policy (Path, Method, Auth) | Istio `AuthorizationPolicy` & `RequestAuthentication` |
| **Operational Overhead** | **Lowest** (No mesh control plane or daemonset) | Medium (Cilium CNI operator & Hubble) | Medium (istiod + ztunnel daemonset + Waypoint) |
