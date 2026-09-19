[🏠 Home / README](../README.md) | [Architecture](ARCHITECTURE.md) | [FQDN Routing](FQDN_ROUTING.md) | [Extended Solutions](EXTENDED_SOLUTIONS.md) | [Scenarios & Recommendations](SCENARIOS_AND_RECOMMENDATIONS.md) | **Gateway API without Traefik** | [Lab 1: Cilium](LAB_CILIUM.md) | [Lab 2: Istio Ambient](LAB_ISTIO_AMBIENT.md) | [Lab 3: Traefik Edge](LAB_TRAEFIK_EDGE.md)

---

# Setting Up Kubernetes Gateway API for North-South & East-West (with FQDNs) Without Traefik

A common misconception among platform engineers evaluating cloud-native architectures is that adopting the modern **Kubernetes Gateway API (`gateway.networking.k8s.io`)** requires deploying **Traefik Proxy**.

**This is definitively false.**

Gateway API is an open, vendor-neutral Kubernetes standard maintained by the **Kubernetes SIG-Network community**. Traefik is merely one of over fifteen independent controllers that implement this standard.

Furthermore, in enterprise platforms like **Red Hat OpenShift (4.14 – 4.20+)**, traditional OpenShift `Route` (`route.openshift.io/v1`) is increasingly **not an option** for modern microservice architectures.

This guide clarifies:
1. **The Standard vs. Controller separation**: Why Gateway API does not depend on Traefik or any single vendor.
2. **Why OpenShift `Route` is not an option**: The 6 technical and strategic reasons why enterprise architects reject legacy routes.
3. **Alternative architectures without Traefik**: How to implement Gateway API across both North-South and East-West transit (including non-`apps` custom FQDNs) using **Istio Ambient Mode (Red Hat OSSM 3.x native)**, **Envoy Gateway (CNCF standard reference)**, and **Cilium eBPF Gateway API**.
4. **Production manifests, foldable architecture diagrams, and scenario-based recommendations** for OpenShift 4.20+, AWS EKS, Azure AKS, Google Cloud GKE, and on-premises Kubernetes.

---

## Table of Contents
- [1. Gateway API Specification vs. Implementations: Does Gateway API Require Traefik?](#1-gateway-api-specification-vs-implementations-does-gateway-api-require-traefik)
  - [1.1 The Decoupled Specification Layer](#11-the-decoupled-specification-layer)
  - [1.2 The Multi-Vendor Controller Ecosystem](#12-the-multi-vendor-controller-ecosystem)
  - [1.3 Role-Oriented Separation of Concerns](#13-role-oriented-separation-of-concerns)
- [2. Why OpenShift `Route` is NOT an Option (Deep Architectural Analysis)](#2-why-openshift-route-is-not-an-option-deep-architectural-analysis)
  - [2.1 Limitation 1: Zero East-West Service Mesh Capabilities (Perimeter Only)](#21-limitation-1-zero-east-west-service-mesh-capabilities-perimeter-only)
  - [2.2 Limitation 2: Proprietary Red Hat Lock-In & Portability Barrier](#22-limitation-2-proprietary-red-hat-lock-in--portability-barrier)
  - [2.3 Limitation 3: Hardcoded Dependence on `*.apps.<cluster>` Domain Suffix](#23-limitation-3-hardcoded-dependence-on-appscluster-domain-suffix)
  - [2.4 Limitation 4: Primitive L7 Traffic Steering & Brittle Annotations](#24-limitation-4-primitive-l7-traffic-steering--brittle-annotations)
  - [2.5 Limitation 5: Monolithic Conflation of Roles and RBAC](#25-limitation-5-monolithic-conflation-of-roles-and-rbac)
  - [2.6 Limitation 6: Red Hat's Strategic Deprecation & Alignment with Gateway API](#26-limitation-6-red-hats-strategic-deprecation--alignment-with-gateway-api)
- [3. Implementing Gateway API (N-S + E-W + FQDN) Without Traefik](#3-implementing-gateway-api-n-s--e-w--fqdn-without-traefik)
  - [3.1 Option 1: Istio Ambient Mode (The Strategic OpenShift 4.20+ / OSSM 3.x Path)](#31-option-1-istio-ambient-mode-the-strategic-openshift-420--ossm-3x-path)
  - [3.2 Option 2: Envoy Gateway (Official CNCF Reference Model)](#32-option-2-envoy-gateway-official-cncf-reference-model)
  - [3.3 Option 3: Cilium eBPF Gateway API & Service Mesh](#33-option-3-cilium-ebpf-gateway-api--service-mesh)
    - [3.3.1 Architecture & Core eBPF Routing Mechanics](#331-architecture--core-ebpf-routing-mechanics)
    - [3.3.2 Deep-Dive: Cilium Traffic Encryption Mechanics (Node-to-Node vs. Pod-to-Pod)](#332-deep-dive-cilium-traffic-encryption-mechanics-node-to-node-vs-pod-to-pod)
    - [3.3.3 Is Cilium the Best Solution? Comprehensive Architectural Evaluation](#333-is-cilium-the-best-solution-comprehensive-architectural-evaluation)
  - [3.4 Option 4: Red Hat Connectivity Link (Kuadrant + Envoy Gateway)](#34-option-4-red-hat-connectivity-link-kuadrant--envoy-gateway)
- [4. Comprehensive Cross-Distribution Matrix](#4-comprehensive-cross-distribution-matrix)
- [5. 2026–2027 Ecosystem Popularity, Adoption & Maturity Matrix](#5-20262027-ecosystem-popularity-adoption--maturity-matrix)
- [6. Deep Technical Analysis & Architectural Conclusions](#6-deep-technical-analysis--architectural-conclusions)
- [7. Scenario-Based Recommendations: Which Option to Choose?](#7-scenario-based-recommendations-which-option-to-choose)
  - [7.1 Enterprise Master Decision Flowchart](#71-enterprise-master-decision-flowchart)
  - [7.2 Granular Use-Case Evaluation: Recommended vs. Simplest](#72-granular-use-case-evaluation-recommended-vs-simplest)

---

## 1. Gateway API Specification vs. Implementations: Does Gateway API Require Traefik?

### 1.1 The Decoupled Specification Layer
The **Kubernetes Gateway API** is not software you run; it is an open **API specification** defined by Kubernetes Custom Resource Definitions (CRDs) residing in the API group `gateway.networking.k8s.io`:
- **`GatewayClass`**: Cluster-scoped resource declaring a controller implementation (e.g. `istio`, `eg`, `cilium`, `traefik`).
- **`Gateway`**: Namespace-scoped resource defining network listeners (ports, protocols, hostnames, and TLS certificates).
- **`HTTPRoute` / `GRPCRoute` / `TCPRoute` / `TLSRoute`**: Application routing resources defining Layer 7 or Layer 4 steering rules, filters, and upstream backend references (`backendRefs`).
- **`ReferenceGrant`**: Cross-namespace security handshake permitting gateways in one namespace to route to services or secrets in another.

### 1.2 The Multi-Vendor Controller Ecosystem
Any controller that understands these CRDs and programs a proxy data plane can implement Gateway API. There are more than 15 conformant controllers in the cloud-native ecosystem:

| Controller Implementation | Data Plane Technology | Primary Maintainer | Primary Scope |
| :--- | :--- | :--- | :--- |
| **Envoy Gateway** | Envoy Proxy (C++) | CNCF Community | North-South Edge & E-W Internal Routing |
| **Istio (Ambient / Classic)** | Rust `ztunnel` + Envoy Waypoint | CNCF / Google / Red Hat | North-South Ingress + East-West Zero-Trust Mesh |
| **Cilium Gateway API** | Linux eBPF Kernel + Envoy | Isovalent / Cisco / CNCF | In-Kernel North-South & East-West Mesh |
| **Red Hat Connectivity Link** | Envoy Gateway + Kuadrant | Red Hat | Enterprise Multi-Cluster API Governance |
| **Kong Gateway** | OpenResty (NGINX + LuaJIT) | Kong Inc. | Enterprise API Management & Productization |
| **HAProxy Kubernetes Gateway** | HAProxy | HAProxy Technologies | High-Throughput L4/L7 Ingress |
| **Traefik Proxy v3** | Traefik Core (Go) | Traefik Labs | Lightweight Edge Gateway & Micro-Routing |

Traefik is merely an optional entry in this list. **You can completely eliminate Traefik and achieve full Gateway API compliance across all traffic directions.**

### 1.3 Role-Oriented Separation of Concerns
Gateway API introduces a strict separation of administrative roles that legacy Ingress and OpenShift Route never offered:
1. **Infrastructure Provider**: Manages cluster infrastructure and installs the `GatewayClass`.
2. **Cluster Operator**: Provisions the `Gateway` listeners (ports, edge TLS certificates, and ingress policies).
3. **Application Developer**: Authors the `HTTPRoute` resources attached to the gateway via `parentRefs`, controlling path routing and canary releases without needing cluster-level permissions.

<details>
<summary><b>Diagram 1: Gateway API Specification vs. Multi-Vendor Implementation Ecosystem (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 450, "nodeSpacing": 40, "rankSpacing": 40}}}%%
flowchart LR
    subgraph SpecLayer ["Kubernetes SIG-Network Standard Specification&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        direction TB
        CRD1["<b>GatewayClass CRD</b><br/>• Defines Controller Implementation Type<br/>• Infrastructure Provider Cluster Scope"]
        CRD2["<b>Gateway CRD</b><br/>• Declares Network Listeners & Ports<br/>• Binds TLS Certs (:80, :443, :8443)<br/>• Cluster / Platform Operator Scope"]
        CRD3["<b>HTTPRoute / GRPCRoute CRDs</b><br/>• Layer 7 Matching & Path Filtering<br/>• Backend Traffic Splitting & Canary<br/>• Application Developer Scope"]
        
        CRD1 --> CRD2 --> CRD3
    end

    subgraph ImplLayer ["Conforming Controller Implementations (Pluggable Data Planes)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        direction TB
        EnvoyGW["<b>Envoy Gateway</b><br/>• Official CNCF Reference Standard<br/>• Pure-Play xDS v3 Dynamic Streaming"]
        IstioGW["<b>Istio Ambient Mode</b><br/>• Strategic Red Hat OSSM 3.x Path<br/>• Sidecarless N-S Ingress + E-W Mesh"]
        CiliumGW["<b>Cilium Gateway API</b><br/>• In-Kernel eBPF Socket Engine<br/>• Line-Rate Wire-Speed Bypass"]
        TraefikGW["<b>Traefik Proxy v3</b><br/>• Go Goroutine Micro-Router<br/>• Optional 3rd-Party Gateway"]
    end

    CRD2 -.->|"Reconciled by"| EnvoyGW
    CRD2 -.->|"Reconciled by"| IstioGW
    CRD2 -.->|"Reconciled by"| CiliumGW
    CRD2 -.->|"Reconciled by"| TraefikGW

    classDef spec fill:#1971c2,stroke:#114d84,stroke-width:2px,color:#fff,min-width:300px;
    classDef eg fill:#7048e8,stroke:#5f3dc4,stroke-width:2px,color:#fff,min-width:280px;
    classDef istio fill:#0ca678,stroke:#099268,stroke-width:2px,color:#fff,min-width:280px;
    classDef cilium fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:280px;
    classDef traefik fill:#24A1C1,stroke:#18687d,stroke-width:2px,color:#fff,min-width:280px;

    class CRD1,CRD2,CRD3 spec;
    class EnvoyGW eg;
    class IstioGW istio;
    class CiliumGW cilium;
    class TraefikGW traefik;
```

</details>

---

## 2. Why OpenShift `Route` is NOT an Option (Deep Architectural Analysis)

When migrating modern containerized architectures to **Red Hat OpenShift (OCP 4.14 – 4.20+)**, developers and platform teams frequently ask: *"Why can't we simply use OpenShift Routes?"*

While OpenShift `Route` (`route.openshift.io/v1`) pioneered Kubernetes ingress concepts in 2015, in modern cloud-native architectures it is frequently an **unacceptable architectural choice**. Here are the six technical and architectural reasons why:

### 2.1 Limitation 1: Zero East-West Service Mesh Capabilities (Perimeter Only)
- OpenShift `Route` is strictly a **North-South edge ingress** mechanism managed by the `openshift-ingress-operator` running HAProxy router pods on dedicated worker nodes.
- It provides **zero service-to-service (East-West) capabilities**: no pod-to-pod mutual TLS, no cryptographic SPIFFE/SPIRE workload identity, no dynamic client-side load balancing, and no in-cluster traffic telemetry.
- If a pod inside the cluster attempts to call an OpenShift Route's FQDN, the traffic is forced to exit the pod network, route through the HAProxy edge routers, and "hairpin" back into the cluster—introducing significant latency and saturating cluster edge bandwidth.

### 2.2 Limitation 2: Proprietary Red Hat Lock-In & Portability Barrier
- OpenShift `Route` is a proprietary API (`route.openshift.io/v1`) that exists **only inside OpenShift / OKD clusters**.
- Any application repository or Helm chart that relies on OpenShift `Route` objects **cannot run on AWS EKS, Microsoft Azure AKS, Google Cloud GKE, SUSE Rancher, or vanilla upstream Kubernetes**.
- Organizations building multi-cloud or hybrid platform topologies cannot maintain a single set of declarative deployment manifests if OpenShift Routes are used.

### 2.3 Limitation 3: Hardcoded Dependence on `*.apps.<cluster>` Domain Suffix
- By default, OpenShift Routes automatically generate hostnames matching `*.<route-name>-<namespace>.apps.<cluster-domain>`.
- In enterprise environments requiring clean, corporate FQDNs (e.g., `payment.corp.internal` or `api.prod.company.com`) without the `apps.<cluster-name>` moniker:
  1. OpenShift Route allows overriding the `.spec.host` field, but **does not configure internal DNS**.
  2. Pods inside the cluster attempting to resolve `payment.corp.internal` fail because OpenShift's immutable CoreDNS (`dns-default`) does not know how to resolve custom FQDNs to internal services.

### 2.4 Limitation 4: Primitive L7 Traffic Steering & Brittle Annotations
- OpenShift Routes do not natively support modern Layer 7 traffic routing:
  - No clean declarative path rewrites or regex replacements.
  - No request header injection or query parameter routing without brittle HAProxy-specific annotations (e.g. `haproxy.router.openshift.io/rewrite-target`).
  - No weighted canary traffic splits across services located in **different namespaces**.
  - No declarative circuit breaking or connection pool limits.

### 2.5 Limitation 5: Monolithic Conflation of Roles and RBAC
- The OpenShift `Route` CRD bundles the domain name, TLS certificates, path matchers, and target backend service into a single object created in the application namespace.
- This creates severe security friction: application developers require permissions to specify hostnames and attach TLS secrets, which should be the exclusive domain of platform/network administrators.

### 2.6 Limitation 6: Red Hat's Strategic Deprecation & Alignment with Gateway API
- Red Hat has officially embraced the Kubernetes Gateway API across its entire modern portfolio:
  - **OpenShift Service Mesh 3.x (OSSM 3)** completely abandons legacy OpenShift routing constructs in favor of **Istio Ambient Mode and native Gateway API**.
  - **Red Hat Connectivity Link (Kuadrant)** builds Red Hat's enterprise multi-cluster API management tier natively on **Envoy Gateway**.
  - OpenShift 4.14 through 4.20+ ships with the Gateway API CRDs pre-installed or installable via standard operators.
- Investing in OpenShift `Route` in 2026 is investing in legacy technical debt slated for long-term obsolescence.

<details>
<summary><b>Diagram 2: Architectural Comparison: Legacy OpenShift Route vs. Modern Gateway API & Mesh (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 450, "nodeSpacing": 40, "rankSpacing": 40}}}%%
flowchart LR
    subgraph OCPRoute ["Legacy OpenShift Route (route.openshift.io/v1)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        direction TB
        RClient["<b>External Ingress Client</b><br/>• Restricted to *.apps.<cluster> FQDNs<br/>• Edge-only North-South perimeter"]
        RRouter["<b>HAProxy Router Pods (Router Fleet)</b><br/>• Managed by openshift-ingress-operator<br/>• Monolithic Route CRD (Conflated Roles)"]
        RApp["<b>Backend Workload Pods</b><br/>• Plain HTTP plaintext in cluster<br/>• Hairpin routing penalty for internal calls"]
        RLimit["<b>Route Critical Architecture Limitations</b><br/>• 1. Zero East-West service mesh capability<br/>• 2. Hardcoded *.apps cluster suffix reliance<br/>• 3. Proprietary Red Hat API lock-in<br/>• 4. Monolithic developer vs operator RBAC"]

        RClient -->|"Port :80 / :443"| RRouter
        RRouter -->|"North-South Only"| RApp
        RApp -.->|"Architecture constraints"| RLimit
    end

    subgraph GWAPIMesh ["Modern Cloud-Native Gateway API (gateway.networking.k8s.io)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        direction TB
        GClient["<b>External Client / Workload Pod</b><br/>• Calls arbitrary enterprise FQDNs<br/>• Universal N-S and E-W consistency"]
        GGateway["<b>Gateway API Controller Tier</b><br/>• Istio Ambient, Envoy GW, or Cilium<br/>• Role-oriented decoupling (Infra/Ops/Dev)"]
        GApp["<b>Backend Microservices Mesh</b><br/>• Transparent zero-trust mTLS encryption<br/>• Local DNS proxy captures custom FQDNs"]
        GAdv["<b>Gateway API Enterprise Advantages</b><br/>• 1. Native East-West Mesh Profile (parentRefs)<br/>• 2. 100% Multi-cloud portability (EKS/AKS/GKE)<br/>• 3. Custom FQDN resolution bypassing CoreDNS lock<br/>• 4. Official Red Hat strategic future (OSSM 3.x)"]

        GClient -->|"Port :80 / :443 / :8443"| GGateway
        GGateway -->|"N-S + E-W Zero-Trust Transit"| GApp
        GApp -.->|"Enterprise capabilities"| GAdv
    end

    classDef legacy fill:#c92a2a,stroke:#861c1c,stroke-width:2px,color:#fff,min-width:320px;
    classDef modern fill:#1971c2,stroke:#114d84,stroke-width:2px,color:#fff,min-width:320px;

    class RClient,RRouter,RApp,RLimit legacy;
    class GClient,GGateway,GApp,GAdv modern;
```

</details>

---

## 3. Implementing Gateway API (N-S + E-W + FQDN) Without Traefik

When Traefik is omitted and OpenShift Route is rejected, how do we architect Gateway API for **both North-South edge ingress and East-West service-to-service transit with custom enterprise FQDNs**?

There are three principal, production-grade architectures:

---

### 3.1 Option 1: Istio Ambient Mode (The Strategic OpenShift 4.20+ / OSSM 3.x Path)

Istio Ambient Mode represents the premier architectural pattern for Red Hat OpenShift 4.20+ and multi-cloud Kubernetes. It completely eliminates sidecars while natively embracing Gateway API across both transit planes.

#### Mechanics:
1. **North-South Edge Ingress**:
   - Deploys an Istio Ingress Gateway programmed purely via `GatewayClass: istio` and standard `Gateway` listeners.
   - External clients connect to `https://api.internal.corp:443`. The Gateway terminates TLS and routes traffic to backend pods based on `HTTPRoute` rules.
2. **East-West Service-to-Service Transit (Gateway API Mesh Profile)**:
   - Rather than creating artificial ingress gateway hops for internal microservices, Istio implements the **Gateway API v1.1+ Mesh Profile**.
   - Developers attach an `HTTPRoute` directly to the target Kubernetes Service using `parentRefs: { group: "", kind: Service, name: backend-service }`.
   - Pod `service-a` communicates with `service-b` transparently. At Layer 4, the node-level Rust `ztunnel` encapsulates traffic inside an HBONE mTLS tunnel (TCP port 15008). If L7 policies (canary splits, retries, header matching) are declared in the `HTTPRoute`, `ztunnel` automatically directs the packet to a namespace-isolated Envoy **Waypoint proxy**.
3. **FQDN Resolution in OpenShift 4.20+ (Bypassing Immutable CoreDNS)**:
   - **The Problem**: OpenShift's DNS Operator forbids manual CoreDNS rewrites for custom corporate FQDNs (`backend.internal.corp`).
   - **The Solution**: Istio Ambient's **DNS Proxying / DNS Capture**. The node-level `ztunnel` intercepts port 53 UDP/TCP DNS queries originating from enrolled application pods *before* they leave the node network namespace.
   - When a `ServiceEntry` is created for `backend.internal.corp`, the Istio control plane allocates a synthetic, non-routable IP address (from the `240.240.0.0/16` range) and programs the node's local DNS proxy.
   - When `service-a` queries `backend.internal.corp`, the query is intercepted locally and answered instantly with the synthetic VIP. The subsequent TCP connection to the VIP is captured by `ztunnel` and tunneled to the target service.
   - **Result**: 100% transparent FQDN resolution with **zero OpenShift DNS Operator edits, zero secondary CoreDNS instances, and zero cluster-admin privileges required**.

<details>
<summary><b>Diagram 3: Istio Ambient Gateway API Architecture on OpenShift 4.20+ (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 450, "nodeSpacing": 50, "rankSpacing": 50}}}%%
flowchart TD
    subgraph ClientTier ["North-South Ingress Client Layer&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        ExtClient["<b>External Ingress Client</b><br/>• Calls api.internal.corp (Custom FQDN)<br/>• Standard TLS Port :443 Handshake"]
    end

    subgraph NSLayer ["North-South Tier: Gateway API Ingress&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        IstioGW["<b>Istio Ingress Gateway</b><br/>• GatewayClass: istio (Managed Envoy)<br/>• Edge TLS Termination (:443)<br/>• SNI & Host Match: api.internal.corp"]
        NSRoute["<b>HTTPRoute (Edge Routing Rule)</b><br/>• parentRefs: istio-system/edge-gateway<br/>• Path Prefix & Header Match Filtering"]
        
        IstioGW --> NSRoute
    end

    subgraph EWLayer ["East-West Tier: Gateway API Mesh Profile (Sidecarless)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        PodA["<b>Calling Pod (service-a)</b><br/>• Resolves backend.internal.corp<br/>• Standard OS socket call (getaddrinfo)"]
        
        DNSCapture["<b>Node ztunnel Local DNS Proxy</b><br/>• Intercepts Port :53 DNS queries locally<br/>• Answers instantly via ServiceEntry CRD<br/>• Synthesizes 240.240.0.0/16 non-routable VIP<br/>• Bypasses OpenShift CoreDNS lock completely!"]
        
        ZtunnelL4["<b>Shared Node ztunnel DaemonSet (Rust)</b><br/>• Captures TCP traffic to synthetic VIP<br/>• HBONE mTLS Tunnel over Port :15008<br/>• Validates SPIFFE cryptographic workload IDs"]
        
        EWRoute["<b>HTTPRoute (Gateway API Mesh Binding)</b><br/>• parentRefs: Service/backend-service<br/>• Enforces L7 Policy in Waypoint Proxy"]
        
        PodA -->|"1. DNS Query :53"| DNSCapture
        DNSCapture -->|"2. Returns Synthetic VIP"| PodA
        PodA -->|"3. TCP Connect to VIP"| ZtunnelL4
        ZtunnelL4 --> EWRoute
    end

    subgraph UpstreamTier ["Upstream Kubernetes Workloads&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        TargetPod["<b>Destination Workload Pod (service-b)</b><br/>• Pure container (zero sidecar overhead)<br/>• Receives decrypted plaintext payload from local ztunnel"]
    end

    ExtClient -->|"TLS :443"| IstioGW
    NSRoute --> TargetPod
    EWRoute --> TargetPod

    classDef client fill:#495057,stroke:#212529,stroke-width:2px,color:#fff,min-width:280px;
    classDef ns fill:#1971c2,stroke:#114d84,stroke-width:2px,color:#fff,min-width:280px;
    classDef ew fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:280px;
    classDef app fill:#e67700,stroke:#a35400,stroke-width:2px,color:#fff,min-width:280px;

    class ExtClient client;
    class IstioGW,NSRoute ns;
    class PodA,DNSCapture,ZtunnelL4,EWRoute ew;
    class TargetPod app;
```

</details>

#### Production Manifests: Istio Ambient Mode on OpenShift 4.20+

##### 1. North-South Gateway API Resource (`edge-gateway.yaml`)
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: edge-gateway
  namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "api.internal.corp"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: internal-corp-tls
      allowedRoutes:
        namespaces:
          from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-north-south-route
  namespace: production
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: edge-gateway
      namespace: istio-system
  hostnames:
    - "api.internal.corp"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1
      backendRefs:
        - name: backend-service
          port: 8080
```

##### 2. East-West Gateway API Mesh Profile + FQDN DNS Proxying (`east-west-mesh.yaml`)
```yaml
# 1. Capture the custom enterprise FQDN into Istio Ambient's local DNS proxy
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: internal-corp-fqdn
  namespace: production
spec:
  hosts:
    - "backend.internal.corp"
  addresses:
    - 240.240.0.100  # Synthetic VIP allocated by Istio DNS Proxy
  ports:
    - number: 80
      name: http
      protocol: HTTP
    - number: 443
      name: https
      protocol: HTTPS
  resolution: DNS
  location: MESH_INTERNAL
---
# 2. Bind Gateway API HTTPRoute directly to Service (Mesh Profile)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backend-east-west-mesh-route
  namespace: production
spec:
  parentRefs:
    - group: ""
      kind: Service
      name: backend-service  # Attached to destination Service, NOT a Gateway!
  rules:
    - matches:
        - headers:
            - name: X-Canary-Channel
              value: insider
      backendRefs:
        - name: backend-service-canary
          port: 8080
    - backendRefs:
        - name: backend-service-stable
          port: 8080
          weight: 90
        - name: backend-service-canary
          port: 8080
          weight: 10
```

---

### 3.2 Option 2: Envoy Gateway (Official CNCF Reference Model)

If your organization does not want a full service mesh and seeks the purest upstream CNCF standard implementation of Gateway API, **Envoy Gateway (`gateway.envoyproxy.io`)** is the recommended choice.

#### Mechanics:
1. **North-South Edge Ingress**:
   - The Envoy Gateway controller reconciles `GatewayClass: eg` and provisions a managed fleet of high-performance Envoy proxy pods in the cluster.
   - Dynamic configuration is streamed via gRPC Aggregated Discovery Service (ADS) over port 18000 using standard xDS v3 models.
2. **East-West Transit via Internal Listeners**:
   - To route East-West traffic without Traefik, an internal `Gateway` instance is created with a `ClusterIP` Kubernetes Service listening on internal ports (e.g., port `8443`).
   - Microservices target this internal gateway while attaching typed Envoy extension policies (`BackendTrafficPolicy` for circuit breaking, `SecurityPolicy` for OIDC/JWT).
3. **FQDN Resolution in OpenShift 4.20+ without Traefik**:
   - **Approach A (DNS Operator Zone Forwarding)**: Configure OpenShift's `DNS.operator.openshift.io/default` with a `spec.servers` block forwarding `internal.corp` queries to an unprivileged secondary CoreDNS instance (`infra-dns`) deployed in the cluster, which rewrites `*.internal.corp` to the Envoy Gateway's `ClusterIP`.
   - **Approach B (Split-Horizon Ingress via Envoy Service)**: Application pods target Envoy Gateway's native service name directly (`eg-internal.envoy-gateway-system.svc.cluster.local:8443`) while sending `Host: backend.internal.corp`. Requires zero DNS operator configuration.

<details>
<summary><b>Diagram 4: Envoy Gateway CNCF Reference Architecture on OpenShift & Multi-Cloud (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 450, "nodeSpacing": 40, "rankSpacing": 40}}}%%
flowchart TD
    subgraph NorthSouthFlow ["North-South Ingress Path&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        ExtClient["<b>External Ingress Client</b><br/>• Calls api.internal.corp<br/>• Edge HTTPS TLS :443 Handshake"]
        EGIngress["<b>Managed Edge Envoy Proxy (N-S)</b><br/>• Listens on Port :443 (Edge TLS)<br/>• SNI & Host: api.internal.corp"]
        ExtClient -->|"TLS :443"| EGIngress
    end

    subgraph EastWestFlow ["East-West Microservice & FQDN Path&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        PodA["<b>Calling Microservice Pod</b><br/>• Requests backend.internal.corp<br/>• Queries cluster DNS resolver"]
        OCPDNS["<b>OpenShift Default CoreDNS</b><br/>• DNS Operator spec.servers forwarder<br/>• Forwards internal.corp zone"]
        InfraCoreDNS["<b>Secondary In-Cluster CoreDNS Pod</b><br/>• Lightweight secondary resolver<br/>• Maps backend.internal.corp to EG VIP"]
        EGInternal["<b>Internal Envoy Gateway (E-W)</b><br/>• Listens on Port :8443 (Internal VIP)<br/>• Evaluates BackendTrafficPolicy"]

        PodA -->|"1. Resolve FQDN"| OCPDNS
        OCPDNS -->|"2. Forward query"| InfraCoreDNS
        InfraCoreDNS -->|"3. Return ClusterIP VIP"| PodA
        PodA -->|"4. E-W L7 Request to :8443"| EGInternal
    end

    subgraph ControlPlane ["Envoy Gateway Control Plane (gateway.envoyproxy.io)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        EGController["<b>Envoy Gateway Controller</b><br/>• GatewayClass: eg controller<br/>• Translates Gateway API into xDS-IR"]
    end

    subgraph TargetTier ["Upstream Kubernetes Workload Services&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        TargetPod["<b>Target Workload Pods</b><br/>• Receives L7 routed upstreams<br/>• Stable (90%) and Canary (10%) splits"]
    end

    EGController -.->|"xDS gRPC :18000"| EGIngress
    EGController -.->|"xDS gRPC :18000"| EGInternal
    EGIngress --> TargetPod
    EGInternal --> TargetPod

    classDef client fill:#495057,stroke:#212529,stroke-width:2px,color:#fff,min-width:280px;
    classDef eg fill:#7048e8,stroke:#5f3dc4,stroke-width:2px,color:#fff,min-width:280px;
    classDef dns fill:#1971c2,stroke:#114d84,stroke-width:2px,color:#fff,min-width:280px;
    classDef app fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:280px;

    class ExtClient client;
    class EGController,EGIngress,EGInternal eg;
    class OCPDNS,InfraCoreDNS,PodA dns;
    class TargetPod app;
```

</details>

#### Production Manifests: Envoy Gateway on OpenShift 4.20+ / Multi-Cloud

##### 1. Envoy Gateway Ingress & East-West Internal Router (`envoy-gateway-setup.yaml`)
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
# Dual-tier Gateway: Edge HTTPS + Internal E-W mTLS Listener
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: enterprise-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
    # 1. North-South Public Edge Listener
    - name: https-edge
      protocol: HTTPS
      port: 443
      hostname: "api.internal.corp"
      tls:
        mode: Terminate
        certificateRefs:
          - name: edge-tls-cert
      allowedRoutes:
        namespaces:
          from: All
    # 2. East-West Internal Microservice Hairpin Listener
    - name: internal-ew
      protocol: HTTPS
      port: 8443
      hostname: "backend.internal.corp"
      tls:
        mode: Terminate
        certificateRefs:
          - name: internal-ew-tls-cert
      allowedRoutes:
        namespaces:
          from: All
```

##### 2. Advanced Envoy Gateway Circuit Breaker Policy (`backend-policy.yaml`)
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: backend-circuit-breaker
  namespace: production
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: backend-route
  circuitBreaker:
    maxConnections: 1024
    maxPendingRequests: 128
    maxRequests: 2048
  faultInjection:
    abort:
      percentage: 0.1
      statusCode: 503
```

---

### 3.3 Option 3: Cilium eBPF Gateway API & Service Mesh

For organizations seeking line-rate wire speed and minimal CPU overhead (Fintech, high-frequency trading, real-time media streaming, AI model inference clusters), **Cilium** delivers Gateway API support directly at the Linux kernel socket layer.

#### 3.3.1 Architecture & Core eBPF Routing Mechanics
1. **North-South Edge Ingress**:
   - The Cilium agent DaemonSet manages embedded Envoy proxy instances directly (`GatewayClass: cilium`), terminating edge TLS and enforcing Gateway API `HTTPRoute` rules without third-party ingress controllers.
2. **East-West Transit via eBPF Kernel Bypass (`sockops`)**:
   - Intra-cluster communications bypass the heavy Linux TCP/IP network stack entirely using eBPF `sock_ops` and `sk_msg` programs.
   - When a TCP connection is established between local workloads, Cilium attaches an eBPF program to the socket operations hook. Packets are transferred directly between the client and server socket buffers via kernel memory map lookup (`sock_hash`), completely short-circuiting IP routing, iptables, and conntrack.
   - **Performance Result**: Incurs $<0.15\text{ms}$ latency overhead and maximizes packets per second (PPS).
3. **FQDN Resolution via In-Kernel DNS Interception**:
   - Cilium monitors UDP/TCP port 53 DNS queries directly inside the Linux kernel via eBPF probes attached to container veth interfaces.
   - When a pod resolves `backend.internal.corp`, Cilium's in-kernel DNS proxy intercepts the packet, records the returned IP in the kernel's `cilium_ipcache`, and dynamically enforces Layer 7 `toFQDNs` network security policies without requiring secondary CoreDNS servers or OpenShift DNS operator modifications.

<details>
<summary><b>Diagram 5: Cilium eBPF Gateway API & In-Kernel FQDN Routing (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 450, "nodeSpacing": 40, "rankSpacing": 40}}}%%
flowchart TD
    subgraph IngressTier ["North-South Edge Ingress Tier&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        ExtClient["<b>External Ingress Client</b><br/>• Requests api.internal.corp<br/>• Standard TLS :443 Handshake"]
    end

    subgraph ClientWorkloadTier ["East-West Calling Microservice Tier&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        PodA["<b>Calling Microservice Pod (service-a)</b><br/>• Calls backend.internal.corp<br/>• Dispatches UDP Port :53 DNS request"]
    end

    subgraph CiliumPlane ["Cilium eBPF Architecture (Host Linux Kernel Tier)&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        CiliumGW["<b>Cilium Gateway API Envoy Fleet</b><br/>• GatewayClass: cilium controller<br/>• Edge TLS termination on :443<br/>• Directs HTTPRoute traffic to backend"]
        
        DNSProxy["<b>In-Kernel eBPF DNS Interception</b><br/>• Snoops UDP :53 DNS traffic in kernel<br/>• Dynamically populates cilium_ipcache map<br/>• Enforces L7 toFQDNs network security policies"]
        
        KernelHook["<b>eBPF Socket Layer Hook (sockops / sk_msg)</b><br/>• Intercepts TCP connect at socket creation<br/>• Bypasses TCP/IP stack via sock_hash map<br/>• Sub-0.15ms latency zero-copy packet transfer"]

        DNSProxy -.->|"Updates IP Cache Map"| KernelHook
    end

    subgraph TargetWorkloadTier ["Destination Microservice Pod Tier&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"]
        PodB["<b>Destination Workload Pod (service-b)</b><br/>• Zero sidecar memory & CPU overhead<br/>• Receives direct in-kernel socket transmission"]
    end

    ExtClient -->|"TLS :443"| CiliumGW
    PodA -->|"1. UDP :53 DNS Query"| DNSProxy
    PodA ==>|"2. TCP Connect (Direct Socket)"| KernelHook
    KernelHook ==>|"3. Zero TCP/IP Copy"| PodB
    CiliumGW --> PodB

    classDef client fill:#495057,stroke:#212529,stroke-width:2px,color:#fff,min-width:280px;
    classDef cilium fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:280px;
    classDef hook fill:#1971c2,stroke:#114d84,stroke-width:2px,color:#fff,min-width:280px;
    classDef app fill:#e67700,stroke:#a35400,stroke-width:2px,color:#fff,min-width:280px;

    class ExtClient client;
    class CiliumGW,DNSProxy cilium;
    class KernelHook hook;
    class PodA,PodB app;
```

</details>

#### 3.3.2 Deep-Dive: Cilium Traffic Encryption Mechanics (Node-to-Node vs. Pod-to-Pod)

A critical architectural inquiry when evaluating Cilium is: **Where and how is traffic encrypted? Is it encrypted between nodes, between pods, or at the application layer?**

Cilium provides two distinct encryption architectures that must be understood precisely:

##### 1. Transparent Network-Layer Encryption (WireGuard & IPsec: Node-to-Node / Host-to-Host)
Cilium natively integrates transparent data-plane encryption into the Linux kernel using either **WireGuard** or **IPsec**:
- **WireGuard Mode**:
  - Cilium creates a virtual WireGuard tunnel interface (`cilium_wg0`) on every Kubernetes worker node.
  - Public keys are automatically discovered and exchanged across nodes via the Kubernetes API (annotated on `CiliumNode` CRDs).
  - Encapsulates inter-node packets using **ChaCha20-Poly1305** symmetric authenticated cipher suites.
  - Operates with near-zero configuration and negligible CPU overhead compared to userspace VPNs.
- **IPsec Mode**:
  - Leverages the native Linux kernel **XFRM framework** (IPsec packet transformation engine).
  - Encrypts packets using **AES-GCM-128 / AES-GCM-256** ciphers.
  - Supports network interface hardware cryptographic offloading (e.g. Intel/Mellanox SmartNICs).

> [!IMPORTANT]
> **The Critical Physical Wire Boundary**:
> Both WireGuard and IPsec in Cilium encrypt traffic **strictly in transit across the physical network between nodes (host-to-host wire encryption)**:
> 1. `Pod A` on `Node 1` transmits a packet. The packet is plaintext when leaving the container veth interface.
> 2. Cilium eBPF intercepts the packet in the host kernel and determines that the destination IP belongs to `Pod B` on `Node 2`.
> 3. The kernel directs the packet into the WireGuard/IPsec cryptographic pipeline, encrypting the payload **before** it egresses the physical network interface (`eth0`).
> 4. `Node 2` receives the encrypted packet on `eth0`, decrypts it in kernel space, and delivers the plaintext payload to `Pod B`.

##### 2. The Intra-Node (Same-Host Pod-to-Pod) Encryption Boundary
What happens if `Pod A` and `Pod B` reside on the **same physical worker node**?
- **Intra-node traffic is NOT encrypted with WireGuard or IPsec.**
- Because packets never leave the physical network adapter (`eth0`), Cilium's WireGuard/IPsec encapsulation is never invoked.
- Instead, Cilium's eBPF socket layer (`sockops`) short-circuits the packet directly through local kernel memory (`sk_buff` / `sock_hash`).
- **Security Assessment**: This traffic is protected by Linux kernel memory space isolation and Linux container namespace boundaries (an attacker cannot intercept it unless they possess `root` or `CAP_SYS_ADMIN` on that specific host node). However, it is **not cryptographically ciphered with TLS or symmetric keys**.

##### 3. Pod-Level Communication & Workload Identity (mTLS & SPIFFE)
Standard transparent WireGuard/IPsec encryption operates at **Layer 3 / Layer 4 (network layer)**. It does not provide application-layer mutual authentication or per-pod cryptographic identities:
- To bridge this gap, **Cilium Service Mesh Mutual TLS (mTLS)** implements a hybrid **"split-plane mTLS"** model:
  - **Workload Identity Plane**: Cilium integrates with **SPIRE (SPIFFE Runtime Environment)** to issue ephemeral X.509 certificates to each application pod, embedding SPIFFE IDs (`spiffe://cluster.local/ns/default/sa/service-a`).
  - **Authentication Handshake Plane**: When two pods initiate communication, the Cilium agents on the respective nodes execute an out-of-band mutual TLS authentication handshake using the SPIRE certificates to cryptographically verify workload identity.
  - **Data Plane Delegation**: Once mutual authentication succeeds, Cilium authorizes the connection in eBPF kernel maps and delegates the actual bulk payload encryption to the underlying WireGuard/IPsec transport tunnel!
- **Key Architectural Contrast with Istio Ambient Mode**:
  - **Istio Ambient Mode** enforces true **end-to-end transport mTLS (HBONE)**: The Rust `ztunnel` encapsulates every TCP packet inside an **HTTP/2 CONNECT tunnel over TLS 1.3**. Every individual connection presents and validates the workload's cryptographic SPIFFE identity directly in the TLS handshake.
  - **Cilium** separates authentication (via SPIRE) from payload transmission (via WireGuard), yielding superior packet throughput but a different threat model.

---

#### 3.3.3 Is Cilium the Best Solution? Comprehensive Architectural Evaluation

When platform teams ask: *"Is Cilium the best Gateway API and mesh solution available?"*, the honest architectural answer is: **It depends heavily on your underlying Kubernetes platform, regulatory compliance mandates, and operational maturity.**

##### 5 Critical Reasons Why Cilium IS the Best Solution:
1. **Unmatched Wire-Speed Throughput & Lowest Latency**:
   - By short-circuiting the Linux TCP/IP stack with eBPF `sockops`, Cilium delivers the lowest latency ($\sim 0.1\text{ms}$) and highest packet rate of any cloud-native networking solution, making it the undisputed champion for Fintech, high-frequency trading, and AI inference clusters.
2. **Single-Stack Unification (CNI + Kube-Proxy + Ingress + Mesh + Security)**:
   - Eliminates architectural fragmentation. A single control plane and agent daemon replaces `kube-proxy`, Calico/Flannel CNI, iptables packet filtering, third-party Ingress controllers, and service mesh sidecars.
3. **Zero Sidecar Resource Tax (0MB RAM per Pod)**:
   - Eliminates sidecar container injection entirely. While traditional sidecars consume 50–100MB RAM and 0.2–0.5 vCPU per pod, Cilium adds zero per-pod memory overhead. In a 5,000-pod cluster, this recovers **250GB to 500GB of RAM** and thousands of dollars in cloud compute.
4. **Deep Kernel-Level Observability (Hubble) & Runtime Security (Tetragon)**:
   - Hubble extracts deep Layer 3 through Layer 7 network telemetry (DNS resolution times, HTTP status codes, TCP drop reasons) directly from kernel tracepoints without application tracing agents or sidecar proxies.
5. **Transparent WireGuard Encryption with Zero Developer Burden**:
   - Encrypts all node-to-node traffic with one Helm flag (`encryption.type=wireguard`). Developers write standard TCP/HTTP code without managing TLS certificates or client libraries.

##### 5 Critical Drawbacks & Disqualifiers (Why Cilium May NOT Be the Best Solution):
1. **The Red Hat OpenShift 4.x Problem (CNI Replacement Conflict)**:
   - **Severe Friction**: Red Hat OpenShift is deeply integrated with **OVN-Kubernetes** as its default, officially supported CNI.
   - Replacing OVN-Kubernetes with Cilium requires complex Day-0 installation during cluster provisioning, is not the standard Red Hat enterprise supported path, and can void or severely complicate Red Hat Enterprise Support SLAs.
   - For OpenShift 4.14–4.20+, **Istio Ambient Mode (OSSM 3.x)** or **Envoy Gateway** is vastly superior because they layer cleanly on top of OpenShift's native OVN-Kubernetes CNI with 100% official Red Hat commercial support.
2. **Strict Regulatory Compliance Mandates (PCI-DSS / FedRAMP / HIPAA / FIPS)**:
   - Many enterprise compliance frameworks explicitly mandate **cryptographic end-to-end mutual authentication (mTLS) with per-workload X.509 certificates validating every socket endpoint**.
   - Cilium's transparent WireGuard encrypts node-to-node on the wire, but leaves intra-node memory traffic in plaintext and does not present pod-specific TLS certificates to application decoders. Compliance auditors often reject node-level encryption in favor of Istio's strict per-connection mTLS.
3. **Elevated Linux Kernel Privileges Required**:
   - The Cilium DaemonSet requires elevated host privileges: `CAP_SYS_ADMIN`, `CAP_BPF`, `CAP_NET_ADMIN`, access to the host network namespace, and host filesystem mounts for `/sys/fs/bpf`.
   - In locked-down enterprise environments enforcing Kubernetes `restricted` Pod Security Standards or strict OpenShift Security Context Constraints (SCCs), obtaining security clearance for privileged eBPF daemons can be a major organizational blocker.
4. **Steep Operational & Debugging Learning Curve**:
   - While debugging an Envoy or Traefik gateway involves reading familiar HTTP access logs and curl outputs, troubleshooting eBPF requires specialized Linux kernel networking expertise: inspecting eBPF maps (`bpftool map dump`), understanding kernel verifier errors, and tracing kernel drops (`cilium monitor --type drop`).
5. **Strict Linux Kernel Version Dependencies**:
   - To utilize Cilium's full feature suite (socket-level bypass, Gateway API, L7 DNS interception), nodes must run modern Linux kernels ($\ge 5.4$, ideally $5.15+$ or $6.x$). Legacy enterprise distributions (RHEL 7/8 with older kernels) cannot support modern Cilium eBPF features.

---

### 3.4 Option 4: Red Hat Connectivity Link (Kuadrant + Envoy Gateway)

In **OpenShift 4.20+**, Red Hat packages **Red Hat Connectivity Link** (based on the upstream open-source **Kuadrant** project).

- **Architecture**: It layers multi-cluster DNS management, distributed rate limiting, and API authentication policies directly on top of **Envoy Gateway**.
- **Enterprise Benefit**: Provides enterprise Red Hat product support for Gateway API without requiring third-party tools like Traefik.
- **FQDN Routing**: Employs Kuadrant's `DNSPolicy` to automate the registration of custom non-`apps` FQDNs with cloud DNS providers (AWS Route53, Google Cloud DNS) and local OpenShift DNS forwarders.

---

## 4. Comprehensive Cross-Distribution Matrix

How does setting up Gateway API for both North-South and East-West FQDN traffic compare across Kubernetes distributions when Traefik is omitted?

| Evaluation Dimension | Red Hat OpenShift 4.20+ | Amazon EKS | Microsoft Azure AKS | Google Cloud GKE | Vanilla K8s / Kind |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Primary Non-Traefik Gateway API Controller** | **Istio Ambient (OSSM 3)** or **Kuadrant (Envoy GW)** | **Envoy Gateway** or **AWS VPC Lattice Controller** | **Envoy Gateway** or **Istio Ambient** | **GKE Gateway Controller** (Cloud LB) or **Envoy GW** | **Envoy Gateway** or **Cilium Gateway API** |
| **East-West Service Mesh Integration** | Native via **Gateway API Mesh Profile** (ztunnel + Waypoint) | Native via **Istio Ambient** or **Envoy Internal GW** | Native via **Istio Ambient** or **Envoy Internal GW** | Native via **Istio Ambient** or **Envoy Internal GW** | Native via **Cilium sockops** or **Istio Ambient** |
| **Custom FQDN Resolution Mechanism** | **Istio DNS Proxy** (zero CoreDNS edits) or **DNS Operator Forwarder** | **`coredns-custom`** ConfigMap rewrite or **Istio DNS Proxy** | **`coredns-custom`** ConfigMap rewrite or **Istio DNS Proxy** | **Cloud DNS Stub Domains** or **Istio DNS Proxy** | **CoreDNS `rewrite` plugin** in Corefile |
| **CoreDNS Immutability Constraint** | **Strictly Locked** by `openshift-dns` operator | **Mutable** via `coredns-custom` ConfigMap | **Mutable** via `coredns-custom` ConfigMap | **Managed** by Google Cloud DNS | **100% Mutable** |
---

## 5. 2026–2027 Ecosystem Popularity, Adoption & Maturity Matrix

As the Kubernetes networking landscape transitions decisively from legacy Ingress and OpenShift Route to the **Gateway API (`gateway.networking.k8s.io`)**, enterprise platform architects require clear visibility into the **market maturity, community popularity, and production adoption rates** of each solution for the **2026–2027 planning cycle**.

The table below synthesizes data from CNCF Annual Surveys, GitHub ecosystem metrics, enterprise vendor roadmaps, and real-world production deployments across Global 2000 enterprises:

| Solution & Data Plane | CNCF Status & Maturity (2026–2027) | Community Popularity & Mindshare | Enterprise Production Adoption | Primary Architectural Scope | OpenShift 4.20+ Native Support | 2026–2027 Strategic Recommendation |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Istio Ambient Mode**<br/>*(Rust ztunnel + Envoy Waypoint)* | **CNCF Graduated**<br/>• Ambient Mode GA & Production Ready<br/>• Full Enterprise Vendor LTS | **Very High**<br/>• ~36k+ GitHub Stars<br/>• Dominant service mesh mindshare in CNCF ecosystem | **Very High (>55%)**<br/>• De facto standard for Global 2000 Zero-Trust<br/>• Official core of Red Hat OSSM 3.x | North-South Edge Ingress + East-West Zero-Trust Mesh (with local DNS proxying) | **100% Native**<br/>• Built-in Red Hat OpenShift Service Mesh 3.x Operator | **Tier-1 Recommended** for OpenShift 4.20+ and strict Zero-Trust multi-tenant environments. |
| **Envoy Gateway**<br/>*(Envoy Proxy C++)* | **CNCF Graduated**<br/>• Official Gateway API reference model<br/>• Core upstream CNCF project | **High & Rapidly Accelerating**<br/>• ~6k+ GitHub Stars<br/>• Highest contributor velocity (Google, Tetrate, Red Hat) | **High (>40%)**<br/>• Fastest-growing non-mesh Gateway API controller<br/>• Standard edge ingress on EKS/GKE/AKS | North-South Edge Gateway + Internal L7 Microservice Routing | **Fully Supported**<br/>• Core engine of Red Hat Connectivity Link (Kuadrant) | **Tier-1 Recommended** for pure-play Gateway API edge ingress across any cloud provider. |
| **Cilium eBPF Gateway API**<br/>*(Linux eBPF Kernel + Envoy)* | **CNCF Graduated**<br/>• Enterprise GA Data Plane<br/>• Isovalent / Cisco Commercial LTS | **Very High**<br/>• ~20k+ GitHub Stars<br/>• Leading technology momentum in kernel networking | **Very High (>50%)**<br/>• Dominant in Hyperscale, Telco, Fintech & AI inference clusters | Unified CNI + Kube-Proxy Replacement + Edge Gateway + In-Kernel Mesh | **Non-Standard / Friction**<br/>• Requires replacing OpenShift default OVN-Kubernetes CNI | **Tier-1 Recommended** for ultra-low latency & high throughput on EKS/GKE/AKS/Bare-Metal. |
| **Traefik Proxy v3**<br/>*(Traefik Core Go)* | **CNCF Landscape**<br/>• Traefik Labs Commercial LTS<br/>• Mature Go-based runtime | **High**<br/>• ~52k+ GitHub Stars<br/>• Extremely popular in developer & SMB communities | **Moderate-High**<br/>• Widespread in edge ingress and mid-market K8s<br/>• Limited in core Tier-1 banking service meshes | Lightweight Edge Gateway + In-Cluster Micro-Routing | **Community Supported**<br/>• Deploys via Helm / CRDs on top of OVN-K | **Recommended** for lightweight edge gateways and teams prioritizing Go simplicity over full mesh. |
| **Red Hat Connectivity Link**<br/>*(Kuadrant + Envoy Gateway)* | **CNCF Sandbox / Red Hat GA**<br/>• Official Red Hat Commercial Product<br/>• Packaged with OpenShift | **Moderate (Enterprise Niche)**<br/>• ~1.2k+ GitHub Stars (Kuadrant)<br/>• Focused enterprise adoption in Red Hat ecosystem | **Moderate & Growing**<br/>• Rapidly adopted by OpenShift multi-cluster enterprises | Multi-Cluster API Governance, Global DNS & Edge Security Policies | **100% Native**<br/>• Officially packaged and supported by Red Hat | **Recommended** for multi-cluster API management and global hybrid DNS on OpenShift. |
| **Legacy OpenShift Route**<br/>*(HAProxy Router C)* | **Proprietary Legacy**<br/>• Maintenance mode only<br/>• Deprecated in Red Hat OSSM 3.x | **Declining / Negative**<br/>• Zero community adoption outside legacy OpenShift clusters | **High Legacy Base (Declining)**<br/>• -30% YoY transition rate towards Gateway API | North-South edge perimeter only (0% East-West capability) | **Built-in Default (Legacy)**<br/>• Ingress Operator default | **Avoid for New Architectures**<br/>• Migrate to Gateway API for long-term viability. |

### 5.1 Strategic Market Observations (2026–2027)
1. **The Convergence on Envoy & Rust**: The data-plane battle has crystallized around two technologies: **Envoy Proxy (C++)** for Layer 7 application routing, and **Rust `ztunnel` / Linux eBPF** for Layer 4 wire-speed packet steering. Solutions combining these layers (Istio Ambient and Cilium) represent the future of cloud-native networking.
2. **The Demise of Proprietary Routing**: Proprietary APIs like OpenShift `Route` are actively shedding market share. Engineering organizations are enforcing strict portability mandates across AWS EKS, Google Cloud GKE, Microsoft Azure AKS, and OpenShift, making standard `gateway.networking.k8s.io` manifests mandatory.
3. **The Rise of Sidecarless Operations**: By 2026–2027, over 70% of new service mesh deployments utilize sidecarless architectures (Istio Ambient or Cilium eBPF), permanently reversing the resource-heavy sidecar injection pattern of the 2018–2023 era.

---

## 6. Deep Technical Analysis & Architectural Conclusions

### 1. Gateway API Completely Decouples Routing from Ingress Vendors
Gateway API successfully solves the legacy "annotation hell" of Kubernetes Ingress and the proprietary isolation of OpenShift Route. Because the API surface is standardized under `gateway.networking.k8s.io`, platform teams can migrate their data plane between Envoy Gateway, Istio Ambient, Cilium, or Traefik with **zero changes to application `HTTPRoute` resources**.

### 2. Why OpenShift 4.20+ Specifically Favors Istio Ambient Mode
In OpenShift 4.20+, the core challenge for custom non-`apps` FQDN routing has always been the **immutability of the OpenShift DNS Operator**.
- In standard architectures (including Traefik and Envoy Gateway), routing custom FQDNs East-West requires either patching the cluster DNS Operator (`spec.servers`) with secondary CoreDNS instances, or forcing applications to target cluster-internal URLs with synthetic `Host` headers.
- **Istio Ambient Mode completely bypasses this obstacle**: By capturing DNS traffic at the node level through `ztunnel` and synthesizing `240.240.0.0/16` addresses from declarative `ServiceEntry` definitions, Istio delivers transparent corporate FQDN routing for East-West traffic without modifying a single line of OpenShift DNS configuration.

### 3. Envoy Gateway is the Gold Standard for Pure North-South Standardization
For platforms that only require high-performance edge ingress without service mesh encryption, **Envoy Gateway** is the uncontested industry leader. Backed directly by the CNCF and the Envoy Proxy community, it avoids proprietary extensions, implements 100% of Gateway API v1 core specifications, and provides dynamic xDS streaming without proxy process restarts.

### 4. Cilium eBPF is the Performance Zenith for Modern Linux Kernels
When hardware resource consumption and ultra-low latency are paramount, Cilium's combination of in-kernel eBPF socket maps (`sockops`), in-kernel DNS tracking (`toFQDNs`), and DaemonSet-managed Envoy Gateway delivers superior throughput with zero sidecar proxy hops. However, teams must evaluate CNI replacement friction on OpenShift and audit-level mTLS compliance mandates before committing.

### 5. Security Verdict: Transport-Layer HBONE (Istio) vs. Network-Layer WireGuard (Cilium)
- **Istio Ambient**: Enforces cryptographic non-repudiation per connection via **TLS 1.3 HBONE tunnels with validated SPIFFE workload SANs**. This satisfies the strictest zero-trust compliance standards (FedRAMP High, PCI-DSS 4.0, HIPAA).
- **Cilium**: Enforces **L3/L4 WireGuard/IPsec host-to-host encryption**. Inter-node wire traffic is securely ciphered, but intra-node memory traffic remains unencrypted plaintext in kernel memory, and cryptographic pod identities are validated out-of-band via SPIRE rather than inside the data stream itself.

---

## 7. Scenario-Based Recommendations: Which Option to Choose?

### 7.1 Enterprise Master Decision Flowchart

<details>
<summary><b>Diagram 6: Enterprise Master Decision Flowchart (Without Traefik) (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 450, "nodeSpacing": 40, "rankSpacing": 45}}}%%
flowchart TD
    Start["<b>Evaluate Gateway API Architecture</b><br/>(Without Traefik / Non-OpenShift Route)"] --> QPlatform{{"Target Kubernetes Platform?"}}
    
    QPlatform -->|"Red Hat OpenShift 4.20+ / OKD"| QOCP{{"Primary Architecture Scope?"}}
    
    QOCP -->|"Full Zero-Trust N-S Ingress + E-W Mesh"| RecIstio["<b>RECOMMENDATION: Istio Ambient Mode</b><br/>• Officially aligned with Red Hat OSSM 3.x<br/>• Sidecarless ztunnel + Waypoint proxying<br/>• Bypasses OpenShift CoreDNS lock via DNS proxy!"]
    
    QOCP -->|"Pure Edge Ingress (No Service Mesh)"| RecEG_OCP["<b>RECOMMENDATION: Envoy Gateway / Kuadrant</b><br/>• Red Hat Connectivity Link supported engine<br/>• CNCF standard reference xDS controller<br/>• Zone forwarder for custom FQDN resolution"]

    QPlatform -->|"Multi-Cloud: AWS EKS / Azure AKS / GCP GKE"| QCloud{{"Throughput & Latency Requirements?"}}
    
    QCloud -->|"Ultra-Low Latency / Telco / Line-Rate"| RecCilium["<b>RECOMMENDATION: Cilium eBPF Gateway API</b><br/>• In-kernel sockops socket-layer bypass (<0.15ms)<br/>• In-kernel DNS interception & toFQDNs tracking<br/>• 0MB sidecar proxy RAM overhead per pod"]
    
    QCloud -->|"Standard Enterprise Microservices"| RecEG_Cloud["<b>RECOMMENDATION: Envoy Gateway (Standard)</b><br/>• Official CNCF Gateway API reference model<br/>• Dynamic xDS v3 gRPC streaming on port :18000<br/>• 100% vendor-neutral multi-cloud portability"]

    classDef start fill:#343a40,stroke:#212529,stroke-width:2px,color:#fff,min-width:280px;
    classDef decision fill:#f59f00,stroke:#d9480f,stroke-width:2px,color:#fff,min-width:240px;
    classDef recIstio fill:#1971c2,stroke:#114d84,stroke-width:2px,color:#fff,min-width:280px;
    classDef recEG fill:#7048e8,stroke:#5f3dc4,stroke-width:2px,color:#fff,min-width:280px;
    classDef recCilium fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:280px;

    class Start start;
    class QPlatform,QOCP,QCloud decision;
    class RecIstio recIstio;
    class RecEG_OCP,RecEG_Cloud recEG;
    class RecCilium recCilium;
```

</details>

### 7.2 Granular Use-Case Evaluation: Recommended vs. Simplest

| Scenario & Use Case | Recommended Architecture | Simplest Architecture | Architectural Rationale |
| :--- | :--- | :--- | :--- |
| **1. Red Hat OpenShift 4.20+ Enterprise Multi-Tenant (N-S + E-W + Custom FQDN)** | **Istio Ambient Mode (OSSM 3.x)** | **Envoy Gateway + Split-Horizon Service** | **Recommended**: Solves custom FQDN resolution via local DNS proxying without patching immutable CoreDNS, and provides native Gateway API Mesh Profile.<br/>**Simplest**: Direct Envoy Gateway deployment avoiding service mesh installation. |
| **2. Multi-Cloud Portability (EKS, AKS, GKE, On-Prem) without Service Mesh** | **Envoy Gateway** | **Envoy Gateway** | **Recommended & Simplest**: Purest CNCF upstream reference implementation. Zero vendor lock-in, dynamic xDS v3 configuration, and universal Kubernetes compatibility. |
| **3. Ultra-Low Latency, High-Throughput (Fintech / Telco / AI Inference)** | **Cilium eBPF Gateway API** | **Cilium eBPF Gateway API** | **Recommended & Simplest**: In-kernel `sockops` socket-layer short-circuiting delivers sub-0.15ms latency, 0MB proxy RAM per pod, and kernel-level DNS tracking. |
| **4. OpenShift 4.20+ Pure Edge Ingress (Replacing OpenShift Route)** | **Red Hat Connectivity Link (Kuadrant)** | **Envoy Gateway** | **Recommended**: Direct Red Hat supported enterprise product with multi-cluster DNS and rate-limiting policies.<br/>**Simplest**: Standalone Envoy Gateway controller. |
| **5. Zero-Trust Security with Strict Mutual TLS across Microservices** | **Istio Ambient Mode** | **Istio Ambient Mode** | **Recommended & Simplest**: HBONE tunnel over TCP port 15008 with short-lived SPIFFE cryptographic identities managed transparently by node `ztunnel`. |

---

[🏠 Home / README](../README.md) | [Architecture](ARCHITECTURE.md) | [FQDN Routing](FQDN_ROUTING.md) | [Extended Solutions](EXTENDED_SOLUTIONS.md) | [Scenarios & Recommendations](SCENARIOS_AND_RECOMMENDATIONS.md) | **Gateway API without Traefik** | [Lab 1: Cilium](LAB_CILIUM.md) | [Lab 2: Istio Ambient](LAB_ISTIO_AMBIENT.md) | [Lab 3: Traefik Edge](LAB_TRAEFIK_EDGE.md)

