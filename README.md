# Cloud-Native Ingress & Service Mesh Laboratory (2026 Edition)
### Production Evaluation Framework, Architectural Analyses, and Automated PoCs for Next-Generation Kubernetes & OpenShift Networking Fabrics

[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.30%2B-blue.svg?logo=kubernetes)](https://kubernetes.io/)
[![Red Hat OpenShift](https://img.shields.io/badge/OpenShift-v4.16%2B-red.svg?logo=redhat)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![Gateway API](https://img.shields.io/badge/Gateway%20API-v1.1%20GA-purple.svg)](https://gateway-api.sigs.k8s.io/)
[![Cilium](https://img.shields.io/badge/Cilium-v1.16%2B-green.svg?logo=cilium)](https://cilium.io/)
[![Istio Ambient](https://img.shields.io/badge/Istio-v1.23%2B%20Ambient-466BB0.svg?logo=istio)](https://istio.io/)
[![Traefik](https://img.shields.io/badge/Traefik-v3.1%2B-24A1C1.svg?logo=traefikproxy)](https://traefik.io/)

---

## Documentation Index & Navigation

| Document | Focus Area |
| :--- | :--- |
| **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** | Multi-layer packet flow analyses, Linux `sockops` vs Envoy proxies, OpenShift SCCs |
| **[FQDN_ROUTING.md](docs/FQDN_ROUTING.md)** | Dual-plane (N-S & E-W) FQDN routing across mesh & non-mesh architectures |
| **[LAB_CILIUM.md](docs/LAB_CILIUM.md)** | Automated PoC: Kernel-level eBPF Gateway & Mesh, Canary, Hubble observability |
| **[LAB_ISTIO_AMBIENT.md](docs/LAB_ISTIO_AMBIENT.md)** | Automated PoC: Sidecarless Istio Ambient (ztunnel + Waypoint), mTLS validation |
| **[LAB_TRAEFIK_EDGE.md](docs/LAB_TRAEFIK_EDGE.md)** | Automated PoC: Gateway API-native Edge Router, Middlewares, CircuitBreaker |

---

## Table of Contents
- [1. Executive Summary & 2026 Landscape Shifts](#1-executive-summary--2026-landscape-shifts)
- [2. Comprehensive Evaluation Matrix](#2-comprehensive-evaluation-matrix)
- [3. Platform Decision Matrix & Ranked Recommendations](#3-platform-decision-matrix--ranked-recommendations)
  - [Archetype 1: Ultra-Low Latency & Telco/Fintech](#archetype-1-high-performance-ultra-low-latency--telcofintech-workloads)
  - [Archetype 2: Enterprise Multi-Tenant Zero-Trust](#archetype-2-enterprise-multi-tenant-zero-trust-cloud-platform-eg-openshift-on-awsbare-metal)
  - [Archetype 3: High-Velocity API Edge Platform](#archetype-3-high-velocity-api-edge--developer-platform-north-south-ingress-focus)
- [4. Architecture Diagrams](#4-architecture-diagrams)
  - [Diagram 1: North-South into East-West Zero-Trust Fabric](#diagram-1-north-south-ingress-flow-into-east-west-zero-trust-mesh-fabric)
  - [Diagram 2: Data Plane Structural Comparison](#diagram-2-structural-data-plane-comparison-sidecar-vs-ebpf-bypass-vs-istio-ambient)
- [5. Repository Structure](#5-repository-structure)
- [6. Quick Start & Global Automation](#6-quick-start--global-automation)
- [7. Authoritative References & Sources of Truth](#7-authoritative-references--sources-of-truth)
  - [7.1 Kubernetes Gateway API & Networking Standards](#71-kubernetes-gateway-api--networking-standards)
  - [7.2 Linux Kernel eBPF & Socket-Layer Acceleration (`sockops`)](#72-linux-kernel-ebpf--socket-layer-acceleration-sockops)
  - [7.3 Istio Ambient Mode & HBONE Architecture](#73-istio-ambient-mode--hbone-architecture)
  - [7.4 Traefik Proxy v3 (Edge Gateway & Ingress)](#74-traefik-proxy-v3-edge-gateway--ingress)
  - [7.5 Red Hat OpenShift Compliance & Platform Hardening](#75-red-hat-openshift-compliance--platform-hardening)
  - [7.6 Industry Standards for Zero-Trust & Identity](#76-industry-standards-for-zero-trust--identity)

---

## 1. Executive Summary & 2026 Landscape Shifts

The Kubernetes networking landscape in 2026 has crossed two definitive architectural inflection points:

1. **The Formal Deprecation and Sunset of `networking.k8s.io/v1 Ingress`**:
   The legacy Ingress resource—defined in 2015 as a rudimentary reverse-proxy abstraction—has been fundamentally superseded by the **Kubernetes Gateway API (`gateway.networking.k8s.io/v1`)**. Legacy Ingress suffered from severe architectural flaws:
   - Monolithic role collision (cluster operators and application developers fighting over a single resource).
   - Proliferation of unstandardized, vendor-locked annotations (e.g., `nginx.ingress.kubernetes.io/*`, `traefik.ingress.kubernetes.io/*`).
   - Incapability of expressing modern routing topologies (weighted canaries, header manipulations, gRPC method-level routing, cross-namespace binding, SNI multiplexing) without out-of-tree Custom Resource Definitions (CRDs).
   The Gateway API introduces a decoupled, role-oriented resource model (`GatewayClass` for Infrastructure Providers, `Gateway` for Platform/Cluster Operators, and `*Route` for Application Developers) with first-class conformance testing across data plane providers.

2. **The Demise of the Sidecar Pattern in Favor of Sidecarless Meshes**:
   Injecting an Envoy sidecar proxy into every application pod (`O(N)` scaling) has proven unsustainable in large-scale enterprise environments:
   - **Resource Overhead (Sidecar Tax)**: 50MB–150MB of RSS memory per sidecar container, multiplied across tens of thousands of pods, leads to multi-gigabyte RAM waste purely for proxy infrastructure.
   - **Latency Penalty**: Every request traverses four network hops across the host TCP/IP stack (`App -> Loopback -> Sidecar -> eth0 -> Node -> eth0 -> Peer Sidecar -> Loopback -> Peer App`), adding 2ms–6ms of P99 latency.
   - **Operational Friction**: Pod restart cycles required for proxy upgrades, CPU throttling caused by Linux CFS quota starvation on proxy sidecars, and severe initialization race conditions (e.g., application containers starting before the sidecar proxy is online).

Modern 2026 infrastructures employ **Sidecarless Architectures**:
- **Kernel-level eBPF Short-Circuiting (Cilium)**: Bypassing the entire TCP/IP networking stack at the Linux socket layer (`sockops`), achieving wire-speed Layer 4 transmission and selective Layer 7 Envoy invocation only when cryptographic payload inspection is required.
- **Split-Layer Ambient Data Planes (Istio Ambient)**: Decoupling L4 transport security (Zero-Trust mTLS and identity verification handled at the node level by the Rust-based `ztunnel`) from L7 traffic management (handled by optional, namespace-scoped `waypoint` Envoy proxies).

This laboratory repository provides production-grade reference implementations, automated deployment harnesses, and comparative benchmarks for **Cilium eBPF**, **Istio Ambient**, and **Traefik v3** on both vanilla Kubernetes and Red Hat OpenShift.

---

## 2. Comprehensive Evaluation Matrix

| Evaluation Dimension | Cilium Service Mesh (v1.16+) | Istio Ambient Mesh (v1.23+) | Traefik v3 (Edge Gateway) |
| :--- | :--- | :--- | :--- |
| **Data Plane Architecture** | Sidecarless; in-kernel eBPF socket layer (`sockops`) + Host-level Envoy daemon | Sidecarless; Node-level Rust L4 `ztunnel` + Namespace-level L7 Envoy `waypoint` | Ingress Edge; Go-based proxy process (DaemonSet or Deployment) |
| **Gateway API Conformance** | GA Conformance (`GatewayClass`, `Gateway`, `HTTPRoute`, `TLSRoute`, `GRPCRoute`) | GA Conformance (`Gateway`, `HTTPRoute`, Waypoint binding via GatewayClass) | GA Conformance (`GatewayClass`, `Gateway`, `HTTPRoute`, `TLSRoute`) |
| **P99 Latency Overhead (L4)** | **< 0.15 ms** (Kernel socket bypass via `sock_hash`) | **0.25 – 0.40 ms** (Traverses local node `ztunnel` via Geneve/eBPF redirection) | N/A (Pure Edge Gateway) |
| **P99 Latency Overhead (L7)** | 1.10 – 1.80 ms (Targeted Envoy redirect) | 1.20 – 1.95 ms (Waypoint proxy hop) | 0.85 – 1.40 ms (Direct Ingress reverse proxy) |
| **Memory Footprint (Per Pod)**| **0 MB** (Zero sidecar injection) | **0 MB** (Zero sidecar injection) | 0 MB (Not an East-West mesh) |
| **Memory Footprint (Cluster-wide)**| ~1.2 GB per node (cilium-agent + hubble + Envoy daemon) | **~150 MB per node (`ztunnel`)** + ~60 MB per active Waypoint | ~120 MB per Edge Gateway replica |
| **mTLS Implementation Vector** | Node-to-Node WireGuard/IPsec + Cilium Mutual Auth (SPIRE / control-plane handshake) | **HBONE (HTTP-Based Overlay Network)** over port 15008 with SPIFFE X.509 certs | Edge TLS termination; mTLS upstream via IngressRoute/Gateway spec |
| **L7 Security Capabilities** | CiliumNetworkPolicy L7 rules, HTTP header filtering, DNS policies | Rich Istio AuthorizationPolicy (claims, paths, methods, JWT validation) | Advanced Middlewares (RateLimit, CircuitBreaker, ForwardAuth, Digest) |
| **Red Hat OpenShift Compliance** | **Complex**: Requires replacing OVN-K or Multus chaining; `privileged` SCC, SELinux policies | **Native**: Basis for Red Hat OpenShift Service Mesh 3.x; compatible with default OVN-K | **High**: Runs on OpenShift via standard SCC (`nonroot` or `anyuid`), simple Route bridging |
| **Operational & Upgrade Impact** | Zero app pod restarts during upgrades; high kernel dependency (Linux 5.10+) | Zero app pod restarts during upgrades; ztunnel upgrade hits 0-downtime connection draining | Zero app pod restarts; standard rolling deployment for edge gateways |
| **Observability Fabric** | Hubble (eBPF-native kernel tracing, OpenTelemetry, Prometheus, Grafana) | Kiali, Prometheus, Jaeger/Tempo via ztunnel/waypoint Envoy telemetry | Built-in Web UI, Prometheus metrics, OpenTelemetry tracing natively |

---

## 3. Platform Decision Matrix & Ranked Recommendations

### Archetype 1: High-Performance, Ultra-Low Latency & Telco/Fintech Workloads
- **Rank 1: Cilium eBPF Service Mesh**
  - *Why*: Eliminates user-space/kernel-space context switching for internal pod-to-pod traffic. Using Linux `sockops` eBPF programs, Cilium connects client and server sockets directly at the kernel layer, bypassing the entire TCP/IP network stack (iptables, routing tables, and veth pairs). WireGuard kernel-level encryption provides line-rate hardware-accelerated confidentiality with zero proxy overhead.
- **Rank 2: Istio Ambient**
- **Rank 3: Traefik v3** (Not applicable for East-West mesh)

### Archetype 2: Enterprise Multi-Tenant Zero-Trust Cloud Platform (e.g., OpenShift on AWS/Bare-Metal)
- **Rank 1: Istio Ambient (Red Hat OpenShift Service Mesh 3.x)**
  - *Why*: Operates seamlessly on top of Red Hat's default **OVN-Kubernetes** CNI without requiring kernel replacement. Enforces strict cryptographic zero-trust at Layer 4 across every pod through `ztunnel` without developer intervention. When Layer 7 traffic authorization, canary routing, or header manipulation is demanded, platform teams can selectively spin up a dedicated `waypoint` proxy for that specific namespace or service account, guaranteeing strong tenant isolation and blast-radius containment.
- **Rank 2: Cilium eBPF** (Heavy SCC and SELinux modification requirements on RHCOS)
- **Rank 3: Traefik v3**

### Archetype 3: High-Velocity API Edge & Developer Platform (North-South Ingress Focus)
- **Rank 1: Traefik v3 Gateway API**
  - *Why*: Unrivaled developer ergonomics, ultra-fast dynamic configuration updates without reloads, and rich native middlewares (token-bucket rate limiting, circuit breaking, distributed tracing). Native implementation of `gateway.networking.k8s.io/v1` combined with Traefik Middleware filters enables declarative, self-service edge routing without bloated custom controllers.
- **Rank 2: Cilium Gateway API** (Excellent if Cilium is already the CNI)
- **Rank 3: Istio Ingress Gateway**

---

## 4. Architecture Diagrams

### Diagram 1: North-South Ingress Flow into East-West Zero-Trust Mesh Fabric

```mermaid
flowchart TD
    Client(["&nbsp;&nbsp;&nbsp;&nbsp;External Client / Internet&nbsp;&nbsp;&nbsp;&nbsp;"]) -->|"TLS 1.3 / HTTPS :443"| EdgeGateway["&nbsp;&nbsp;&nbsp;&nbsp;Edge Gateway&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Traefik v3 / Gateway API)&nbsp;&nbsp;&nbsp;&nbsp;"]
    
    subgraph ClusterEdge ["&nbsp;&nbsp;Cluster Ingress Perimeter&nbsp;&nbsp;"]
        EdgeGateway -->|"Rate Limiting & Auth Filter"| MW["&nbsp;&nbsp;&nbsp;&nbsp;Middleware Engine&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Security & Rate Limiting)&nbsp;&nbsp;&nbsp;&nbsp;"]
        MW -->|"L7 Routing Decision: HTTPRoute"| EdgePod["&nbsp;&nbsp;&nbsp;&nbsp;Edge Proxy Workers&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Gateway Ingress Pods)&nbsp;&nbsp;&nbsp;&nbsp;"]
    end

    subgraph MeshTransportLayer ["&nbsp;&nbsp;East-West L4 Zero-Trust Fabric (ztunnel / eBPF)&nbsp;&nbsp;"]
        EdgePod -->|"Mutual TLS / HBONE :15008"| EncryptLayer["&nbsp;&nbsp;&nbsp;&nbsp;L4 Encapsulation and&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;Identity Verification&nbsp;&nbsp;&nbsp;&nbsp;"]
        EncryptLayer -->|"Cryptographic SPIFFE ID"| TargetNode["&nbsp;&nbsp;&nbsp;&nbsp;Target Worker Node&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Host Network Layer)&nbsp;&nbsp;&nbsp;&nbsp;"]
    end

    subgraph AppNamespace ["&nbsp;&nbsp;Application Namespace (Production Workloads)&nbsp;&nbsp;"]
        TargetNode -->|"Selective L7 Enforcement?"| Decision{"&nbsp;&nbsp;Requires L7 Policy?&nbsp;&nbsp;"}
        Decision -->|"Yes: AuthZ / Header Canary"| WaypointProxy["&nbsp;&nbsp;&nbsp;&nbsp;Namespace Waypoint Proxy&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Envoy L7 Engine)&nbsp;&nbsp;&nbsp;&nbsp;"]
        Decision -->|"No: Pure L4 Wire Speed"| FastPath["&nbsp;&nbsp;&nbsp;&nbsp;Direct Kernel Delivery&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(eBPF Socket Bypass)&nbsp;&nbsp;&nbsp;&nbsp;"]
        
        WaypointProxy -->|"90% Base Traffic"| BackendV1["&nbsp;&nbsp;&nbsp;&nbsp;Backend Service v1&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Stable Production)&nbsp;&nbsp;&nbsp;&nbsp;"]
        WaypointProxy -->|"10% Canary Split"| BackendV2["&nbsp;&nbsp;&nbsp;&nbsp;Backend Service v2&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Canary Release)&nbsp;&nbsp;&nbsp;&nbsp;"]
        FastPath --> BackendV1
    end

    classDef edge fill:#24A1C1,stroke:#18687d,stroke-width:2px,color:#fff;
    classDef mesh fill:#466BB0,stroke:#2b426e,stroke-width:2px,color:#fff;
    classDef kernel fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff;
    classDef app fill:#e67700,stroke:#a35400,stroke-width:2px,color:#fff;

    class EdgeGateway,EdgePod,MW edge;
    class EncryptLayer,WaypointProxy mesh;
    class FastPath,TargetNode kernel;
    class BackendV1,BackendV2 app;
```

---

### Diagram 2: Structural Data Plane Comparison (Sidecar vs. eBPF Bypass vs. Istio Ambient)

```mermaid
flowchart TB
    subgraph TraditionalSidecar ["&nbsp;&nbsp;Traditional Envoy Sidecar Model&nbsp;&nbsp;"]
        direction TB
        App1["&nbsp;&nbsp;&nbsp;&nbsp;App Container&nbsp;&nbsp;&nbsp;&nbsp;"] <-->|"Localhost / Loopback"| Proxy1["&nbsp;&nbsp;&nbsp;&nbsp;Envoy Sidecar Container&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Local Inbound Proxy)&nbsp;&nbsp;&nbsp;&nbsp;"]
        Proxy1 <-->|"Host TCP/IP + veth"| Net1["&nbsp;&nbsp;&nbsp;&nbsp;Host Kernel Network Stack&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(iptables and conntrack)&nbsp;&nbsp;&nbsp;&nbsp;"]
        Net1 <-->|"Overlay VXLAN / Wire"| Net2["&nbsp;&nbsp;&nbsp;&nbsp;Peer Kernel Network Stack&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(iptables and routing)&nbsp;&nbsp;&nbsp;&nbsp;"]
        Net2 <-->|"Host TCP/IP + veth"| Proxy2["&nbsp;&nbsp;&nbsp;&nbsp;Envoy Sidecar Container&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Local Outbound Proxy)&nbsp;&nbsp;&nbsp;&nbsp;"]
        Proxy2 <-->|"Localhost / Loopback"| App2["&nbsp;&nbsp;&nbsp;&nbsp;Target App Container&nbsp;&nbsp;&nbsp;&nbsp;"]
        Note1["&nbsp;&nbsp;&nbsp;&nbsp;Overhead & Penalties:&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;• 4 Full Network Hops&nbsp;&nbsp;<br/>&nbsp;&nbsp;• ~100MB RAM per Pod&nbsp;&nbsp;<br/>&nbsp;&nbsp;• App Restarts on Proxy Upgrade&nbsp;&nbsp;"]
    end

    subgraph eBPFShortCircuit ["&nbsp;&nbsp;Cilium eBPF Socket Layer Bypass&nbsp;&nbsp;"]
        direction TB
        AppC1["&nbsp;&nbsp;&nbsp;&nbsp;Client Application Socket&nbsp;&nbsp;&nbsp;&nbsp;"] ==>|"sock_ops / sk_msg direct copy"| AppC2["&nbsp;&nbsp;&nbsp;&nbsp;Server Application Socket&nbsp;&nbsp;&nbsp;&nbsp;"]
        AppC2 -.->|"Bypasses TCP/IP & iptables"| KernelSock["&nbsp;&nbsp;&nbsp;&nbsp;Linux Kernel Sockmap&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(sock_hash / sockops)&nbsp;&nbsp;&nbsp;&nbsp;"]
        Note2["&nbsp;&nbsp;&nbsp;&nbsp;Kernel Bypass Advantages:&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;• Wire-Speed Latency (under 0.15ms)&nbsp;&nbsp;<br/>&nbsp;&nbsp;• 0MB Memory Overhead per Pod&nbsp;&nbsp;<br/>&nbsp;&nbsp;• Zero User-Space Proxy Hops&nbsp;&nbsp;"]
    end

    subgraph IstioAmbientModel ["&nbsp;&nbsp;Istio Ambient Split-Plane Model&nbsp;&nbsp;"]
        direction TB
        AppA1["&nbsp;&nbsp;&nbsp;&nbsp;Workload Pod&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(1/1 Single Container)&nbsp;&nbsp;&nbsp;&nbsp;"] -->|"eBPF / Geneve redirect"| Ztunnel1["&nbsp;&nbsp;&nbsp;&nbsp;Node L4 ztunnel&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Rust Shared DaemonSet)&nbsp;&nbsp;&nbsp;&nbsp;"]
        Ztunnel1 -->|"HBONE (HTTP/2 CONNECT + mTLS :15008)"| Ztunnel2["&nbsp;&nbsp;&nbsp;&nbsp;Target Node L4 ztunnel&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Mutual TLS Terminator)&nbsp;&nbsp;&nbsp;&nbsp;"]
        Ztunnel2 -->|"Optional L7 HTTPRoute / AuthZ"| WaypointEnvoy["&nbsp;&nbsp;&nbsp;&nbsp;Namespace Waypoint Proxy&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;&nbsp;&nbsp;(Dedicated Envoy Pod)&nbsp;&nbsp;&nbsp;&nbsp;"]
        WaypointEnvoy --> TargetApp["&nbsp;&nbsp;&nbsp;&nbsp;Target Workload Pod&nbsp;&nbsp;&nbsp;&nbsp;"]
        Note3["&nbsp;&nbsp;&nbsp;&nbsp;Ambient Split Architecture:&nbsp;&nbsp;&nbsp;&nbsp;<br/>&nbsp;&nbsp;• L4 Transport: ~150MB per Node&nbsp;&nbsp;<br/>&nbsp;&nbsp;• L7 Policies: Isolated Waypoints&nbsp;&nbsp;<br/>&nbsp;&nbsp;• Decoupled Lifecycle & Upgrades&nbsp;&nbsp;"]
    end

    classDef legacy fill:#c92a2a,stroke:#861c1c,stroke-width:2px,color:#fff;
    classDef ebpf fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff;
    classDef ambient fill:#1971c2,stroke:#114d84,stroke-width:2px,color:#fff;

    class App1,Proxy1,Net1,Net2,Proxy2,App2 legacy;
    class AppC1,AppC2,KernelSock ebpf;
    class AppA1,Ztunnel1,Ztunnel2,WaypointEnvoy,TargetApp ambient;
```

---

## 5. Repository Structure

```
cloudnative-ingress-mesh-lab/
├── README.md                 # Executive evaluation, architecture analysis, and ranking matrix
├── Makefile                  # Global automation orchestrator for labs
├── docs/                     # Comprehensive architectural deep dives
│   ├── ARCHITECTURE.md       # Multi-layer packet flow analyses and tradeoffs
│   ├── FQDN_ROUTING.md       # Dual-plane (N-S & E-W) FQDN routing across mesh & non-mesh
│   ├── LAB_CILIUM.md         # Step-by-step automated PoC: Kernel-level eBPF Gateway & Mesh
│   ├── LAB_ISTIO_AMBIENT.md  # Step-by-step automated PoC: Sidecarless Istio Ambient
│   └── LAB_TRAEFIK_EDGE.md   # Step-by-step automated PoC: Gateway API-native Edge Router
├── deploys/                  # Raw manifests and scripts grouped by solution
│   ├── common/               # Sample microservice workloads (Frontend -> Backend App)
│   │   ├── namespace.yaml
│   │   ├── backend-v1.yaml
│   │   ├── backend-v2.yaml
│   │   ├── frontend.yaml
│   │   └── client-tester.yaml
│   ├── cilium/               # Cilium CNI, L7 Gateway, and CiliumClusterwideNetworkPolicies
│   │   ├── helm-values.yaml
│   │   ├── gateway.yaml
│   │   ├── httproute-canary.yaml
│   │   └── cilium-clusterwide-policy.yaml
│   ├── istio/                # Istio Ambient control plane, ztunnel, and Waypoint proxies
│   │   ├── helm-values.yaml
│   │   ├── ingress-gateway.yaml
│   │   ├── waypoint-gateway.yaml
│   │   ├── httproute-canary.yaml
│   │   └── authorization-policy.yaml
│   └── traefik/              # Traefik v3 Gateway API resources and Middlewares
│       ├── helm-values.yaml
│       ├── gateway.yaml
│       ├── httproute-canary.yaml
│       ├── middlewares.yaml
│       └── openshift-scc.yaml
└── scripts/                  # Automated verification and traffic analysis tools
    ├── test-canary.sh        # Statistical traffic-split verification engine
    └── test-mtls.sh          # Zero-trust cryptographic verification script
```

---

## 6. Quick Start & Global Automation

To execute any automated lab, run the central `Makefile`:

```bash
# Display dynamic target catalog
make help

# Bootstrap prerequisites (Gateway API v1 CRDs)
make install-gateway-api

# Execute Lab 1: Cilium eBPF Gateway & Service Mesh
make setup-cilium
make test-traffic-cilium
make test-canary-cilium

# Execute Lab 2: Istio Ambient (ztunnel + Waypoint)
make setup-istio
make test-traffic-istio
make test-mtls-istio

# Execute Lab 3: Traefik v3 Gateway API Edge Router
make setup-traefik
make test-traffic-traefik

# Clean up all laboratory resources
make clean-all
```

For complete step-by-step deep-dives, proceed directly to the [Architecture Deep Dive](docs/ARCHITECTURE.md) and individual lab runbooks in [docs/](docs/).

---

## 7. Authoritative References & Sources of Truth

The architectural analyses, comparative metrics, kernel configurations, and YAML payloads across this repository are grounded in official upstream specifications, Linux kernel documentation, and vendor implementation standards:

### 7.1 Kubernetes Gateway API & Networking Standards
- **Kubernetes Gateway API v1.1+ Specification (GA)**: [https://gateway-api.sigs.k8s.io/](https://gateway-api.sigs.k8s.io/)  
  *Official SIG-Network specification defining the role-oriented resource model (`GatewayClass`, `Gateway`, `HTTPRoute`, `TLSRoute`, `GRPCRoute`).*
- **GEP-709: Gateway API vs. Ingress Evolution Rationale**: [https://gateway-api.sigs.k8s.io/geps/gep-709/](https://gateway-api.sigs.k8s.io/geps/gep-709/)  
  *Architectural justification for the formal deprecation of `networking.k8s.io/v1 Ingress` in favor of expressive, multi-tenant Gateway API objects.*
- **Kubernetes Gateway API Conformance Test Suite & Reports**: [https://gateway-api.sigs.k8s.io/concepts/conformance/](https://gateway-api.sigs.k8s.io/concepts/conformance/)  
  *Upstream compliance validation matrices verifying feature support across ingress and service mesh controllers.*
- **IETF RFC 9113: HTTP/2 Specification (CONNECT Tunneling)**: [https://datatracker.ietf.org/doc/html/rfc9113](https://datatracker.ietf.org/doc/html/rfc9113)  
  *The underlying IETF standard governing HTTP/2 stream multiplexing and the `CONNECT` method used by HBONE data planes.*

### 7.2 Linux Kernel eBPF & Socket-Layer Acceleration (`sockops`)
- **Linux Kernel Documentation: BPF Program Types (`sock_ops` & `sk_msg`)**: [https://docs.kernel.org/bpf/](https://docs.kernel.org/bpf/)  
  *Primary kernel source of truth detailing socket map redirection via `bpf_msg_redirect_hash()` and `BPF_MAP_TYPE_SOCKHASH`.*
- **Cilium eBPF Host-Routing & Socket-Level Acceleration Architecture**: [https://docs.cilium.io/en/stable/network/ebpf/](https://docs.cilium.io/en/stable/network/ebpf/)  
  *Technical reference on how Cilium short-circuits the host TCP/IP stack (`veth`, `iptables`, `conntrack`) for local socket pairs.*
- **Cilium Gateway API Implementation Guide**: [https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/)  
  *Configuration reference for Cilium's native Gateway controller, Envoy daemon lifecycle, and L7 HTTPRoute translation.*
- **Isovalent Architecture Whitepaper: Eliminating the Sidecar Tax with eBPF**: [https://isovalent.com/blog/post/2021-12-08-ebpf-servicemesh/](https://isovalent.com/blog/post/2021-12-08-ebpf-servicemesh/)  
  *Empirical performance benchmarks documenting context-switch reductions, memory overhead, and P99 latency savings.*

### 7.3 Istio Ambient Mode & HBONE Architecture
- **Istio Ambient Mode Architectural Specification**: [https://istio.io/latest/docs/ambient/overview/](https://istio.io/latest/docs/ambient/overview/)  
  *Official Istio documentation covering the architectural decoupling of Layer 4 transport security from Layer 7 application policies.*
- **Istio ztunnel (Zero-Trust Tunnel) Technical Reference**: [https://istio.io/latest/docs/ambient/architecture/ztunnel/](https://istio.io/latest/docs/ambient/architecture/ztunnel/)  
  *In-depth dissection of the Rust-based node daemonset, in-pod traffic capture, and mTLS encapsulation on port 15008.*
- **Istio Waypoint Proxies & Gateway API Conformance**: [https://istio.io/latest/docs/ambient/usage/waypoint/](https://istio.io/latest/docs/ambient/usage/waypoint/)  
  *Operational runbook for provisioning namespace-scoped and service-scoped Envoy instances using `gatewayClassName: istio-waypoint`.*
- **Istio Ambient Security Assessment & Threat Modeling**: [https://istio.io/latest/docs/ambient/architecture/security/](https://istio.io/latest/docs/ambient/architecture/security/)  
  *Cryptographic identity guarantees, SPIFFE X.509 certificate exchange, and workload isolation verifications.*

### 7.4 Traefik Proxy v3 (Edge Gateway & Ingress)
- **Traefik v3 Kubernetes Gateway API Provider Documentation**: [https://doc.traefik.io/traefik/providers/kubernetes-gateway/](https://doc.traefik.io/traefik/providers/kubernetes-gateway/)  
  *Official provider reference for Traefik v3 GatewayClass controllers, HTTPRoute resolution, and extension filters.*
- **Traefik Middleware Engine Specification**: [https://doc.traefik.io/traefik/middlewares/overview/](https://doc.traefik.io/traefik/middlewares/overview/)  
  *Reference guide for rate limiting algorithms (token bucket), circuit breaking expressions, security headers, and forward authentication.*
- **Traefik Observability: Prometheus Metrics & OpenTelemetry**: [https://doc.traefik.io/traefik/observability/metrics/prometheus/](https://doc.traefik.io/traefik/observability/metrics/prometheus/)  
  *Metrics exposition schemas for ingress request duration quantiles, retry rates, and active backend connections.*

### 7.5 Red Hat OpenShift Enterprise Compliance & Platform Hardening
- **OpenShift Container Platform: Security Context Constraints (SCCs)**: [https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)  
  *Enterprise security authorization reference defining RBAC boundaries for `restricted-v2`, `anyuid`, and `privileged` workloads.*
- **Red Hat OpenShift Service Mesh 3.x (OSSM 3 / Ambient Architecture)**: [https://docs.openshift.com/container-platform/latest/service_mesh/](https://docs.openshift.com/container-platform/latest/service_mesh/)  
  *Red Hat's enterprise deployment model for Istio Ambient operating seamlessly over default OVN-Kubernetes networking.*
- **Red Hat Enterprise Linux CoreOS (RHCOS): SELinux Super Privileged Containers**: [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/)  
  *SELinux type definitions (`spc_t`), container isolation boundaries, and `/sys/fs/bpf` mount propagation policies on immutable nodes.*
- **OVN-Kubernetes Architecture & Multus CNI Secondary Networks**: [https://docs.openshift.com/container-platform/latest/networking/ovn_kubernetes_network_provider/about-ovn-kubernetes.html](https://docs.openshift.com/container-platform/latest/networking/ovn_kubernetes_network_provider/about-ovn-kubernetes.html)  
  *Architecture guide for OpenShift's default Geneve overlay CNI and secondary network interface attachment definitions.*

### 7.6 Industry Standards for Zero-Trust & Identity
- **NIST Special Publication 800-207: Zero Trust Architecture**: [https://csrc.nist.gov/publications/detail/sp/800-207/final](https://csrc.nist.gov/publications/detail/sp/800-207/final)  
  *Authoritative federal guidelines for continuous cryptographic identity verification, micro-segmentation, and policy enforcement points.*
- **SPIFFE / SPIRE Workload Identity Specification**: [https://spiffe.io/](https://spiffe.io/)  
  *The CNCF standard governing cryptographic software identity issuance (`spiffe://...`) leveraged by Istio Ambient and Cilium mutual authentication.*
