[🏠 Home / README](../README.md) | [Architecture](ARCHITECTURE.md) | **FQDN Routing** | [Gateway API without Traefik](GATEWAY_API_WITHOUT_TRAEFIK.md) | [Gateway API with Traefik](GATEWAY_API_WITH_TRAEFIK.md) | [Extended Solutions](EXTENDED_SOLUTIONS.md) | [Scenarios & Recommendations](SCENARIOS_AND_RECOMMENDATIONS.md) | [Lab 1: Cilium](LAB_CILIUM.md) | [Lab 2: Istio Ambient](LAB_ISTIO_AMBIENT.md) | [Lab 3: Traefik Edge](LAB_TRAEFIK_EDGE.md)

---

# FQDN-Driven Routing: North-South & East-West Architecture Across Kubernetes Distributions & Red Hat OpenShift 4.20+

[![Dual-Plane FQDN](https://img.shields.io/badge/Traffic-Dual--Plane%20FQDN-purple.svg)](../README.md#diagram-7-dual-plane-fqdn-routing-paradigms-transparent-in-cluster-vs-split-horizon-ingress)
[![OpenShift DNS](https://img.shields.io/badge/OpenShift-DNS%20Operator%20Zone%20Forwarding-EE0000.svg?logo=redhat&logoColor=white)](https://docs.openshift.com/)
[![Traefik v3](https://img.shields.io/badge/Traefik-v3.1%2B%20IngressRoute-24A1C1.svg?logo=traefikproxy&logoColor=white)](https://traefik.io/)
[![CoreDNS](https://img.shields.io/badge/DNS-CoreDNS%20Plugins-1864ab.svg)](https://coredns.io/)
[![Multi-Cloud](https://img.shields.io/badge/Cloud-EKS%20%7C%20AKS%20%7C%20GKE%20%7C%20ROSA-blue.svg)](SCENARIOS_AND_RECOMMENDATIONS.md)

In enterprise cloud-native fabrics, relying solely on Kubernetes internal short-names (`service` or `service.namespace.svc.cluster.local`) introduces operational debt and security non-compliance. Enforcing **Fully Qualified Domain Names (FQDNs)** across both North-South and East-West transit creates environment-agnostic, auditable architectures.

However, DNS interception mechanisms vary fundamentally across Kubernetes distributions. Most notably, **in Red Hat OpenShift (OCP 4.14 – 4.20+), the Cluster DNS Operator reconciles and locks the cluster Corefile, strictly forbidding manual in-place rewrites.**

This document provides definitive configurations across **Red Hat OpenShift (4.14 – 4.20+)**, **AWS EKS**, **Azure AKS**, **Google Cloud GKE**, **Vanilla Kubernetes/RKE2**, and modern **Mesh-Native DNS capture fabrics (Cilium & Istio Ambient)**.

---

## Table of Contents
- [1. Enterprise Rationale: Why FQDNs for Both N-S and E-W?](#1-enterprise-rationale-why-fqdns-for-both-n-s-and-e-w)
  - [1.1 Pitfalls of Cluster-Local Short Names](#11-pitfalls-of-cluster-local-short-names)
  - [1.2 Enterprise Scenarios & Use Cases](#12-enterprise-scenarios--use-cases)
- [2. Distribution-Specific DNS Interception & Settings](#2-distribution-specific-dns-interception--settings)
  - [2.1 Red Hat OpenShift (4.14 – 4.20+): The DNS Operator Paradigm](#21-red-hat-openshift-414--420-the-dns-operator-paradigm)
  - [2.1.1 Architectural Reality Check: Do Traefik IngressRoutes & Middlewares Eliminate CoreDNS?](#211-architectural-reality-check-do-traefik-ingressroutes--middlewares-eliminate-coredns)
  - [2.1.2 Custom FQDNs Lacking OpenShift's Default `*.apps.<clustername>`](#212-custom-fqdns-lacking-openshifts-default-appsclustername)
  - [2.1.3 The 4 Operational Paths for OpenShift 4.20+ (Comparison & Decision Guide)](#213-the-4-operational-paths-for-openshift-420-comparison--decision-guide)
  - [2.1.4 Cross-Repository Deep-Dive: How `traefik-fqdn-management-poc-openshift-aws` Bypasses CoreDNS Forwarders & Pod `hostAliases`](#214-cross-repository-deep-dive-how-traefik-fqdn-management-poc-openshift-aws-bypasses-coredns-forwarders--pod-hostaliases)
  - [2.2 OpenShift Pattern A: DNS Operator Zone Forwarding to In-Cluster Resolver](#22-openshift-pattern-a-dns-operator-zone-forwarding-to-in-cluster-resolver)
  - [2.3 OpenShift Pattern B: Pod-Level `hostAliases` & `dnsConfig` (Unprivileged)](#23-openshift-pattern-b-pod-level-hostaliases--dnsconfig-unprivileged)
  - [2.4 Vanilla Kubernetes, Kind & SUSE RKE2: CoreDNS `rewrite` Plugin](#24-vanilla-kubernetes-kind--suse-rke2-coredns-rewrite-plugin)
  - [2.5 Amazon EKS: `coredns-custom` ConfigMap](#25-amazon-eks-coredns-custom-configmap)
  - [2.6 Microsoft Azure AKS: `coredns-custom` ConfigMap](#26-microsoft-azure-aks-coredns-custom-configmap)
  - [2.7 Google Cloud GKE: Cloud DNS & Kube-DNS Stub Domains](#27-google-cloud-gke-cloud-dns--kube-dns-stub-domains)
- [3. Traefik v3 Implementation (without Traefik Mesh)](#3-traefik-v3-implementation-without-traefik-mesh)
  - [3.1 Traefik Dual-Plane IngressRoute](#31-traefik-dual-plane-ingressroute)
  - [3.2 Enterprise Middleware Pipeline](#32-enterprise-middleware-pipeline)
- [4. Mesh-Native Transparent DNS (Zero CoreDNS Alterations)](#4-mesh-native-transparent-dns-zero-coredns-alterations)
  - [4.1 Cilium eBPF: In-Kernel DNS Proxy & `toFQDNs` Egress Policies](#41-cilium-ebpf-in-kernel-dns-proxy--tofqdns-egress-policies)
  - [4.2 Istio Ambient: Node-Level ztunnel DNS Capture & `ServiceEntry`](#42-istio-ambient-node-level-ztunnel-dns-capture--serviceentry)
- [5. Comprehensive Distribution Comparison Matrix](#5-comprehensive-distribution-comparison-matrix)
- [6. Use-Case Decision Matrix: Recommended vs. Simplest Pattern](#6-use-case-decision-matrix-recommended-vs-simplest-pattern)
  - [6.1 Enterprise Master Decision Flowchart](#61-enterprise-master-decision-flowchart)
  - [6.2 Granular Use-Case Evaluation: Recommended vs. Simplest](#62-granular-use-case-evaluation-recommended-vs-simplest)
- [7. References & Authoritative Sources of Truth](#7-references--authoritative-sources-of-truth)

---

## 1. Enterprise Rationale: Why FQDNs for Both N-S and E-W?

### 1.1 Pitfalls of Cluster-Local Short Names
- **Environment & Namespace Lock-In**: Hardcoding `billing.finance.svc.cluster.local` prevents seamless workload migration between namespaces, clusters, or clouds.
- **Enterprise PKI Incompatibility**: Enterprise CAs (Vault, Venafi, DigiCert) issue X.509 certificates matching corporate domain hierarchies (`*.services.corp.internal`). Generating enterprise-signed certs for `.svc.cluster.local` violates enterprise security baselines and fails audit checks (PCI-DSS 4.0, FedRAMP).
- **Consolidation of L7 Policies without a Mesh**: Platform teams frequently need token-bucket rate limiting, circuit breaking, and security header injection on internal calls without the operational weight of injecting sidecars or running full service meshes.

### 1.2 Enterprise Scenarios & Use Cases

| Use Case | Production Scenario | Architectural Solution |
| :--- | :--- | :--- |
| **Internal API Gateway** | Pod A invokes `billing.internal.corp`. | CoreDNS/OpenShift DNS rewires this to Traefik ClusterIP. Traefik applies rate limiting and auth middlewares before forwarding. |
| **Strangler Fig Migration** | Monolith `api.legacy.corp` runs on-prem; microservices migrate to OpenShift. | In-cluster DNS intercepts `api.legacy.corp`. Traefik routes `/orders` to K8s pods and forwards remaining paths to on-prem IPs. |
| **Corporate Zero-Trust mTLS** | Enterprise mandates TLS 1.3 with corporate SANs matching `*.payments.enterprise.net`. | Applications authenticate peer certificates validated against corporate Root CAs rather than ephemeral cluster CAs. |
| **Dynamic Egress Filtering** | Workloads call external SaaS (`api.stripe.com`, `auth.okta.com`). | Cilium eBPF snoops DNS queries and dynamically updates kernel ipsets to block data exfiltration to unauthorized IPs. |

---

## 2. Distribution-Specific DNS Interception & Settings

### 2.1 Red Hat OpenShift (4.14 – 4.20+): The DNS Operator Paradigm

In OpenShift, cluster DNS is managed by the **Cluster DNS Operator (`dns.operator.openshift.io/v1`)**. 
- **The Immutability Barrier**: The ConfigMap `dns-default` in the `openshift-dns` namespace is continuously reconciled by the DNS Operator. Any manual modification to the `Corefile` will be wiped within seconds.
- **Operator CRD Limitation**: OpenShift's `DNS` custom resource does not expose an arbitrary `rewrite` plugin inside `spec.servers`.
- **Supported Architecture**: Red Hat officially supports configuring **Zone Forwarding (`spec.servers[].forwardPlugin`)** pointing to an internal or external resolver.

---

### 2.1.1 Architectural Reality Check: Do Traefik IngressRoutes & Middlewares Eliminate CoreDNS?

A frequent misconception in cloud-native architecture is:
> *"If I configure a Traefik v3 `IngressRoute` matching `Host(\`backend.internal.corp\`)` and attach Traefik Middlewares, I don't need to add entries to CoreDNS or deploy a secondary resolver in OpenShift 4.20+."*

**The Truth: It depends strictly on transit direction (North-South vs. East-West).**

<details>
<summary><b>Diagram 2.1: North-South vs. East-West DNS Resolution Flow (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 450, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    subgraph NorthSouth ["NORTH-SOUTH TRANSIT (External Client -> Cluster Ingress)"]
        ExtClient["<b>External / Corporate Client</b><br/>• Initiates HTTPS Request<br/>• Target: backend.internal.corp"]
        
        ExtDNS["<b>Corporate / Public DNS (External)</b><br/>• Infoblox / AWS Route 53 / BIND<br/>• Resolves to Ingress VIP / Cloud NLB<br/>• 🎯 0% CoreDNS Query (Zero Cluster Load)"]
        
        IngressVIP["<b>OpenShift Ingress / Traefik Gateway</b><br/>• Terminates TLS 1.3 Handshake<br/>• Inspects HTTP Host Header<br/>• Matches IngressRoute / HTTPRoute Rule"]
        
        NSBackend["<b>Target Microservice Pods</b><br/>• Receives Forwarded Layer 7 Traffic<br/>• Standard Ingress Routing"]

        ExtClient -->|"1. Query FQDN"| ExtDNS
        ExtDNS -->|"2. Returns Ingress VIP"| ExtClient
        ExtClient -->|"3. TCP SYN + TLS + Host Header"| IngressVIP
        IngressVIP -->|"4. Proxies Request"| NSBackend
    end

    NorthSouth ~~~ EastWest

    subgraph EastWest ["EAST-WEST TRANSIT (Pod A -> Pod B inside Cluster)"]
        PodA["<b>Client Pod A in Cluster</b><br/>• curl http://backend.internal.corp<br/>• glibc getaddrinfo consults /etc/resolv.conf"]
        
        ClusterDNS{{"<b>OpenShift Cluster DNS (CoreDNS)</b><br/>Is backend.internal.corp<br/>known to CoreDNS or Forwarder?"}}
        
        NXDomain["<b>NXDOMAIN Error Response</b><br/>• Linux kernel aborts socket connection<br/>• curl: (6) Could not resolve host<br/>• 🚨 Traefik Middlewares NEVER execute!"]
        
        ResolvedVIP["<b>A Record Resolved: Traefik VIP</b><br/>• Resolved via Forwarder, hostAliases,<br/>  or Mesh-Native DNS Capture"]
        
        TraefikEW["<b>Traefik Router / Middlewares</b><br/>• Matches IngressRoute Host Rule<br/>• Executes RateLimit, CircuitBreaker & Auth"]
        
        EWBackend["<b>Target Service Pod B</b><br/>• Receives Governed L7 Traffic<br/>• Successfully Protected"]

        PodA -->|"1. Local DNS Lookup"| ClusterDNS
        ClusterDNS -->|"NO: Unknown Host"| NXDomain
        ClusterDNS -->|"YES: Forwarder / Rewrite"| ResolvedVIP
        ResolvedVIP -->|"2. Return Traefik IP"| PodA
        PodA -->|"3. TCP SYN + HTTP Host"| TraefikEW
        TraefikEW -->|"4. Proxies Request"| EWBackend
    end

    classDef client fill:#495057,stroke:#212529,stroke-width:2px,color:#fff,min-width:300px;
    classDef dns fill:#1864ab,stroke:#0b427a,stroke-width:2px,color:#fff,min-width:300px;
    classDef router fill:#d9480f,stroke:#a63207,stroke-width:2px,color:#fff,min-width:300px;
    classDef backend fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:300px;
    classDef error fill:#c92a2a,stroke:#861919,stroke-width:2px,color:#fff,min-width:300px;
    classDef decision fill:#0b427a,stroke:#1864ab,stroke-width:2px,color:#fff,min-width:340px;

    class ExtClient,PodA client;
    class ExtDNS,ResolvedVIP dns;
    class ClusterDNS decision;
    class IngressVIP,TraefikEW router;
    class NSBackend,EWBackend backend;
    class NXDomain error;
```

</details>

#### Technical Breakdown: The Dual Resolution Pipelines

* **North-South Transit Pipeline**:
  - **Client Resolution**: External clients query corporate or public DNS (Infoblox, AWS Route 53, Cloudflare). CoreDNS inside the OpenShift cluster is never queried.
  - **L4/L7 Handshake**: The client resolves the external Load Balancer / Ingress VIP, opens a TCP socket on port 443, completes TLS negotiation, and transmits HTTP requests containing the `Host: backend.internal.corp` header.
  - **Gateway Ingress**: Traefik or OpenShift HAProxy matches the Host header, applies configured middlewares, and proxies the payload to downstream backend pods.

* **East-West Transit Pipeline**:
  - **Client Resolution**: When Pod A executes `curl http://backend.internal.corp/api`, the Linux kernel network stack inside Pod A reads `/etc/resolv.conf`, which points to the cluster DNS service (`172.30.0.10:53`).
  - **The NXDOMAIN Failure Trap**: If `backend.internal.corp` is not registered in CoreDNS, CoreDNS immediately issues an `NXDOMAIN` response. The application process aborts with `curl: (6) Could not resolve host`.
  - **The Traefik Bypass Reality**: Because the destination IP address was never resolved, Pod A's kernel never transmits a TCP SYN packet. Traefik's listeners, routers, and middlewares are completely bypassed.

#### Why Traefik Middlewares Cannot Bypass DNS Resolution (The OSI Model Boundary)
1. **Layer 3/4 Socket Precedence**: Traefik is an application-layer (Layer 7) reverse proxy. An HTTP request or middleware pipeline cannot physically execute until a TCP three-way handshake (SYN, SYN-ACK, ACK) completes.
2. **Client-Side Resolution**: To send a TCP SYN packet to Traefik, the Linux kernel network stack in Pod A requires a destination IPv4/IPv6 address. When the application calls `http://backend.internal.corp`, the OS runtime invokes `getaddrinfo(3)`, which evaluates `/etc/nsswitch.conf` (`hosts: files dns`).
3. **Traefik Isolation**: Traefik cannot intercept the packet until traffic actually arrives at its listening socket. Without DNS resolution or `/etc/hosts` mapping, the kernel drops or aborts the request before any packet leaves the node.

#### Architectural Analysis & Conclusions

* **Core Finding**: Configuring Traefik `IngressRoute` or Gateway API `HTTPRoute` resources only prepares Traefik's internal routing tables; it does **not** dynamically register records in OpenShift CoreDNS or client `/etc/hosts`.
* **Recommended Solution**:
  - **North-South**: Standard Public or Corporate DNS (Route 53, Infoblox) pointing directly to the Ingress Load Balancer VIP. (Both Recommended and Simplest).
  - **East-West**: Implement a dedicated DNS interception mechanism: Zone Forwarding via `spec.servers` (Pattern A), Split-Horizon Ingress via Traefik Service (`traefik-fqdn-management-poc`), or Mesh-Native interception (Cilium / Istio Ambient).
* **Simplest Solution**:
  - For rapid developer testing: Pod-level `hostAliases`.
  - For cloud-managed OpenShift (ROSA): Split-Horizon Ingress addressing Traefik's native `.svc.cluster.local` with HTTP Host header injection.

---

### 2.1.2 Custom FQDNs Lacking OpenShift's Default `*.apps.<clustername>`

In standard OpenShift installations, routes automatically generate names under the default wildcard domain:
`<route-name>-<namespace>.apps.<cluster-name>.<base-domain>`

When enterprise architecture mandates custom FQDNs without the `.apps` prefix (e.g., `payment.corp.internal` or `api.customer.com`), two primary configuration approaches apply:

#### Approach 1: Native OpenShift Route with Custom `spec.host`
OpenShift natively supports arbitrary custom domains on Routes without requiring `.apps.<clustername>`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: payment-custom-route
  namespace: production
  annotations:
    haproxy.router.openshift.io/timeout: 30s
spec:
  # Explicitly overrides the default .apps.<cluster-name> domain
  host: payment.corp.internal
  to:
    kind: Service
    name: payment-service
    weight: 100
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    certificate: |-
      -----BEGIN CERTIFICATE-----
      MIID... (Corporate / Custom CA Certificate)
      -----END CERTIFICATE-----
    key: |-
      -----BEGIN PRIVATE KEY-----
      MIIE...
      -----END PRIVATE KEY-----
```
*Key OpenShift Guardrail:* Custom hosts on Routes are supported out of the box. Ensure the OpenShift IngressController has `routeAdmission.wildcardPolicy: WildcardsAllowed` if wildcard custom domains (`*.corp.internal`) are used.

#### Approach 2: Traefik v3 IngressRoute (Edge & East-West Gateway)
When using Traefik v3 as the edge gateway on OpenShift (bypassing or fronting the default HAProxy Router), the `IngressRoute` matches the arbitrary FQDN directly:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: payment-traefik-route
  namespace: production
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(`payment.corp.internal`) && PathPrefix(`/v1`)
      kind: Rule
      services:
        - name: payment-service
          port: 8080
      middlewares:
        - name: edge-rate-limit
  tls:
    secretName: corp-internal-tls-secret
```

---

### 2.1.3 The 4 Operational Paths for OpenShift 4.20+ (Comparison & Decision Guide)

To route custom FQDNs lacking `.apps.<clustername>` on OpenShift without violating the DNS Operator immutability, choose from the four authoritative patterns:

| Operational Pattern | OpenShift CoreDNS Modified? | Operator Privileges Needed? | Scope | Maintenance Burden | Recommended When |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1. Upstream Corporate Split-Horizon DNS** | **0% (Zero)** | **None** on Cluster | Entire Cluster | Managed in Enterprise Infoblox / Route53 / BIND | Enterprise DNS team can create `payment.corp.internal` pointing to cluster Ingress VIP. |
| **2. Pod-Level `hostAliases`** | **0% (Zero)** | **None** (Standard developer permissions) | Per-Pod / Per-Deployment | Moderate (Must maintain deployment manifests) | Fast testing, non-admin environments, or isolated microservice pairs. |
| **3. In-Cluster Resolver Forwarding (Pattern A)** | **Zone Forward only** (via `spec.servers`) | **Yes** (`cluster-admin` to patch DNS Operator) | Cluster-wide | Low (Deploys lightweight secondary CoreDNS once) | Enterprise internal FQDNs that don't exist in corporate upstream DNS. |
| **4. Mesh-Native Capture (Cilium / Istio)** | **0% (Zero, Bypassed)** | **None** on DNS (Handled by Mesh CNI/ztunnel) | Mesh-wide | Very Low (Declarative `ServiceEntry` / eBPF) | Cilium eBPF or Istio Ambient is already active in the cluster. |

---

### 2.1.4 Cross-Repository Deep-Dive: How `traefik-fqdn-management-poc-openshift-aws` Bypasses CoreDNS Forwarders & Pod `hostAliases`

In the companion reference architecture:
👉 [**github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws**](https://github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws)

the team implements a production-grade deployment on **Red Hat OpenShift (ROSA v4.14+) on AWS** demonstrating how Traefik Proxy v3 and the Kubernetes Gateway API manage dual-plane FQDNs **without** deploying a secondary in-cluster CoreDNS forwarder and **without** requiring application developers to inject `hostAliases` into their pods.

#### 1. Why the Two Repositories Are Closely Related
Both projects solve the exact same foundational challenge in cloud-native platform engineering:
* **The OpenShift DNS Immutability Barrier**: In OpenShift 4.14–4.20+, the Cluster DNS Operator continuously reconciles `dns-default` in `openshift-dns`, overwriting manual Corefile modifications within seconds.
* **Dual-Plane Transit**: Both address external **North-South** ingress (custom FQDNs bypassing default `.apps.<clustername>`) and internal **East-West** microservice-to-microservice transit.
* **Modern Ingress Standards**: Both implement concurrent dual-stack ingress: Traefik v3 Custom Resource Definitions (`IngressRoute`, `Middleware`, `TLSOption`) and official CNCF Kubernetes Gateway API v1 (`GatewayClass`, `Gateway`, `HTTPRoute`, `BackendTLSPolicy`).

#### 2. The Core Differences in Technical Approach
While they solve the same problem, they adopt two distinct architectural philosophies for East-West name resolution:

<details>
<summary><b>Diagram 2.2: Architectural Approaches to East-West FQDN Resolution (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    subgraph ApproachA ["APPROACH A: Transparent In-Cluster DNS Interception (cloudnative-ingress-mesh-lab)"]
        PodA["<b>Workload Client Pod</b><br/><br/>• Direct Call to Business FQDN:<br/>&nbsp;&nbsp;<b>http://backend.internal.corp/api</b><br/>• Standard OS getaddrinfo resolution<br/>• Zero In-Pod Proxy Configuration"]
        
        OCPDNS["<b>OpenShift Cluster DNS</b><br/><br/>• CoreDNS cluster resolver (dns-default)<br/>• Evaluates spec.servers forwarding rules<br/>• Matches domain: <b>internal.corp</b><br/>• Forwards query to infra-dns:53"]
        
        InfraDNS["<b>Secondary CoreDNS (infra-dns)</b><br/><br/>• Dedicated in-cluster resolver pods<br/>• Executes Corefile rewrite regex rule<br/>• Maps FQDN to Traefik ClusterIP VIP<br/>• Returns VIP to Client Pod"]
        
        TraefikA["<b>Traefik v3 Ingress Router</b><br/><br/>• Listens on internal ClusterIP VIP<br/>• Matches IngressRoute Host rule:<br/>&nbsp;&nbsp;<b>Host('backend.internal.corp')</b><br/>• Applies Middleware security chain<br/>&nbsp;&nbsp;(RateLimit, Auth, Security Headers)"]
        
        DestA["<b>Target Microservice Pods</b><br/><br/>• Upstream workloads (v1 / v2 Canary)<br/>• Receives L7 routed HTTP traffic"]

        PodA -->|"1. Resolves backend FQDN"| OCPDNS
        OCPDNS -->|"2. Forwards to infra-dns:53"| InfraDNS
        InfraDNS -->|"3. Returns Traefik ClusterIP VIP"| PodA
        PodA -->|"4. Sends HTTP to Traefik VIP"| TraefikA
        TraefikA -->|"5. Proxies to backend pods"| DestA
    end

    DestA ~~~ ApproachB

    subgraph ApproachB ["APPROACH B: Split-Horizon Ingress via Traefik Service (traefik-fqdn-management-poc)"]
        PodB["<b>Workload Pod (service-a)</b><br/><br/>• Calls Traefik Native Service:<br/>&nbsp;&nbsp;<b>traefik-loadbalancer.traefik-system.svc:8443</b><br/>• Injects HTTP Host Header:<br/>&nbsp;&nbsp;<b>Host: service-b.apps.cluster.local</b><br/>• Presents Client mTLS Certificate"]
        
        NativeDNS["<b>Native OpenShift CoreDNS</b><br/><br/>• CoreDNS cluster resolver (dns-default)<br/>• Resolves *.svc.cluster.local out-of-the-box<br/>• 100% Native Kubernetes resolution<br/>• 0% DNS Operator patches required<br/>• Returns Traefik Service ClusterIP VIP"]
        
        TraefikB["<b>Traefik v3 Edge Router</b><br/><br/>• Port :8443 Internal Gateway Listener<br/>• Terminates Strict mTLS:<br/>&nbsp;&nbsp;<b>RequireAndVerifyClientCert</b><br/>• Matches incoming HTTP Host Header<br/>• Enforces Pod CIDR network allowlist"]
        
        DestB["<b>Target Pods (service-b)</b><br/><br/>• Upstream service endpoints (:8443)<br/>• Authenticated via mutual TLS (mTLS)<br/>• Isolated via NetworkPolicy"]

        PodB <-->|"1. Resolves traefik svc & 2. Gets ClusterIP VIP"| NativeDNS
        PodB -->|"3. Connects: mTLS Cert + Host Header"| TraefikB
        TraefikB -->|"4. Verifies mTLS & Routes Traffic"| DestB
    end

    classDef app fill:#343a40,stroke:#212529,stroke-width:2px,color:#fff,min-width:380px;
    classDef dns fill:#1864ab,stroke:#0b427a,stroke-width:2px,color:#fff,min-width:380px;
    classDef router fill:#d9480f,stroke:#a63207,stroke-width:2px,color:#fff,min-width:380px;
    classDef target fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:380px;

    class PodA,PodB app;
    class OCPDNS,InfraDNS,NativeDNS dns;
    class TraefikA,TraefikB router;
    class DestA,DestB target;
```

</details>

#### Detailed Comparison & Transit Flow Analysis

* **Approach A: Transparent In-Cluster DNS Interception**:
  - **Workload Ergonomics**: Applications make standard HTTP requests (`http://backend.internal.corp/api`) without knowing that an ingress proxy exists. No client code, headers, or environment variables require modification.
  - **Resolution Mechanics**: The OpenShift DNS Operator uses `spec.servers` zone forwarding to delegate the `internal.corp` domain to an in-cluster secondary CoreDNS resolver (`infra-dns`). The secondary resolver rewrites the domain to the Traefik ClusterIP.
  - **Operational Footprint**: Requires `cluster-admin` permissions to patch `dns.operator.openshift.io/default` and maintains a lightweight secondary deployment in `infra-dns`.

* **Approach B: Split-Horizon Ingress via Traefik Service**:
  - **Workload Ergonomics**: Applications target Traefik's native Kubernetes Service (`https://traefik-loadbalancer.traefik-system.svc.cluster.local:8443`) and pass the logical business domain in the HTTP `Host` header (`Host: service-b.apps.cluster.local`).
  - **Resolution Mechanics**: OpenShift CoreDNS resolves `*.svc.cluster.local` out-of-the-box using the standard Kubernetes service registry. Zero DNS operator patches and zero secondary DNS pods are required.
  - **Security & Policy**: Traefik authenticates the caller via mTLS (`strict-mtls-option`), validates client certificates, inspects OVN-Kubernetes pod CIDR allowlists, and routes to the target workload.

#### Analysis & Architectural Conclusions

* **Core Trade-Off**: Client Transparency vs. Cluster-Admin Privilege / Infrastructure Overhead.
* **Recommended Solution**:
  - **Approach A** is **Recommended** when workloads are legacy, polyglot, or generated from frameworks where injecting custom Host headers into every outgoing HTTP call is technically infeasible or introduces unacceptable developer friction.
  - **Approach B** is **Recommended** for AWS ROSA and enterprise cloud environments where security teams restrict `cluster-admin` privileges, or where platform teams want zero extra DNS infrastructure.
* **Simplest Solution**:
  - **Approach B** is the **Simplest Solution** overall because it eliminates all CoreDNS customizations, zone forwarders, and secondary resolver pods. It operates strictly within standard Kubernetes service networking.

#### 3. How `traefik-fqdn-management-poc-openshift-aws` Bypasses DNS Forwarders
That repository uses three complementary architectural mechanisms:

##### Mechanism 1: The Gateway Ingress Horizon Pattern (Verification Command in README.md)
In [`traefik-fqdn-management-poc-openshift-aws/README.md#validation--verification-testing`](https://github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws#4-validating-east-west-mutual-tls-mtls-enforcement), the East-West validation test is executed as:

```bash
CLIENT_POD=$(oc get pod -l app=service-a -n traefik-crd-poc -o jsonpath='{.items[0].metadata.name}')

# Client calls Traefik's native cluster Service name with internal FQDN Host header
oc exec -n traefik-crd-poc "${CLIENT_POD}" -- \
  curl -k -s --cert /var/run/secrets/tls/client.crt --key /var/run/secrets/tls/client.key \
  -H "Host: service-b.apps.cluster.local" \
  "https://traefik-loadbalancer.traefik-system.svc.cluster.local:8443/api/v1/internal"
```

* **Why No Forwarder Is Needed**: Because the socket target is `traefik-loadbalancer.traefik-system.svc.cluster.local`, OpenShift's standard CoreDNS resolves it immediately without any operator configuration.
* **How Traefik Handles the FQDN**: Traefik's internal listener on port `8443` receives the TCP connection, terminates mTLS via `TLSOption` (`strict-mtls-option`), matches the `Host(`service-b.apps.cluster.local`)` rule on the `IngressRoute` (Solution A) or `HTTPRoute` (Solution B), checks the OVN-Kubernetes pod CIDR (`10.128.0.0/14`) via `middleware-internal-east-west-allowlist`, and proxies traffic to `service-b:8443`.

##### Mechanism 2: Middleware-Based Host Mutation (`middleware-forwarded-host-mutation`)
In `manifests/solution-a-traefik-crds/02-middleware-security.yaml`, Traefik injects:
```yaml
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: "https"
      X-Enterprise-Route-Type: "Solution-A-Traefik-CRD"
```
When consuming microservices call `https://service-b.traefik-crd-poc.svc.cluster.local:8443`, CoreDNS resolves it natively. Traefik's middleware mutates the `Host` header to `api.company.com` and injects `X-Forwarded-Host: api.company.com`, satisfying upstream JWT audience verification and CORS requirements transparently.

##### Mechanism 3: Cloud VPC Private Hosted Zones (AWS Route 53)
In AWS ROSA, private VPC hosted zones (e.g., `service-b.internal.company.com`) are resolved by the AWS VPC Resolver (`AmazonProvidedDNS` at `169.254.169.253` or VPC CIDR + 2). Because OpenShift CoreDNS by default forwards non-cluster queries (`.`) to the node's `/etc/resolv.conf`, the query resolves natively to Traefik's internal NLB VIP without touching OpenShift's DNS Operator.

#### 4. Architectural Comparison: Which Approach to Choose?

| Architectural Dimension | [`cloudnative-ingress-mesh-lab`](../README.md) (This Repo) | [`traefik-fqdn-management-poc-openshift-aws`](https://github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws) |
| :--- | :--- | :--- |
| **Primary Scope** | Multi-Engine Comparative Lab (Traefik, Cilium, Istio Ambient, Linkerd, Envoy, Kong) | Production Implementation on Red Hat OpenShift on AWS (ROSA) |
| **East-West DNS Strategy** | **Transparent In-Cluster Resolution**: Zone forwarder (`infra-dns`), pod `hostAliases`, or in-kernel eBPF / ztunnel capture | **Split-Horizon Ingress**: Targeting Traefik's `svc.cluster.local` + `Host` header, or AWS Route 53 Private Zones |
| **Developer Calling Format** | Standard URL: `http://backend.internal.corp/api` (no headers needed) | Explicit Horizon: `https://traefik.svc.cluster.local:8443` with `-H "Host: ..."` |
| **DNS Operator Configuration** | Required for Pattern A (patch `dns.operator.openshift.io/default` `spec.servers`) | **None** (Zero OpenShift DNS Operator interaction) |
| **Cluster Admin Privileges** | Required for DNS Operator patch; none for `hostAliases` or Ambient mesh | **None** on OpenShift (all manifests deploy under tenant namespaces) |
| **Cloud Provider Dependency** | **Cloud-Agnostic**: Identical behavior on Bare-Metal, Kind, OpenShift, EKS, AKS, GKE | **AWS-Native**: Optimized for AWS NLB, ExternalDNS Route 53, and ROSA VPC networking |
| **East-West mTLS Enforcement** | In-kernel eBPF (Cilium), ztunnel HBONE (Istio Ambient), or Traefik hairpin | Traefik `TLSOption` (`RequireAndVerifyClientCert`) & Gateway API `BackendTLSPolicy` (v1alpha3) |
| **Recommended Production Fit** | When microservices cannot change their calling syntax and require transparent DNS interception across any cloud | When running OpenShift on AWS and platform teams want zero DNS forwarders, zero DNS operator patches, and zero sidecars |

---

### 2.2 OpenShift Pattern A: DNS Operator Zone Forwarding to In-Cluster Resolver (Recommended)

To achieve transparent rewriting of `*.internal.corp` to Traefik v3 on OpenShift 4.14 – 4.20+, deploy a lightweight, unprivileged secondary CoreDNS forwarder in an infrastructure namespace (`infra-dns`), then configure the OpenShift DNS Operator to forward the zone to this resolver.

<details>
<summary><b>Diagram 2.3: OpenShift Pattern A - DNS Operator Zone Forwarding Flow (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    subgraph PatternA ["OpenShift Pattern A: DNS Operator Zone Forwarding to In-Cluster Resolver"]
        WorkloadPod["<b>Workload Client Pod</b><br/><br/>• Calls: <b>http://backend.internal.corp</b><br/>• Standard POSIX getaddrinfo resolution<br/>• Queries Cluster CoreDNS: 172.30.0.10:53"]
        
        DNSOperator["<b>OpenShift CoreDNS (dns-default)</b><br/><br/>• Managed by cluster DNS Operator<br/>• Matches spec.servers zone: <b>internal.corp</b><br/>• Forwards to infra-dns Service IP:53"]
        
        SecondaryDNS["<b>Secondary Resolver (infra-dns)</b><br/><br/>• Unprivileged in-cluster CoreDNS deployment<br/>• rewrite regex rule: (.*).internal.corp -><br/>&nbsp;&nbsp;<b>traefik.traefik-system.svc.cluster.local</b><br/>• Returns Traefik ClusterIP VIP to Client"]
        
        TraefikRouter["<b>Traefik v3 Ingress Router</b><br/><br/>• Listens on ClusterIP: 172.30.50.100<br/>• Matches IngressRoute Host: <b>backend.internal.corp</b><br/>• Executes Middleware Chain (Auth, RateLimit)"]
        
        TargetPod["<b>Target Service Endpoints</b><br/><br/>• Workload pods (v1 / v2 Canary)<br/>• Receives Layer 7 Routed HTTP Traffic"]

        WorkloadPod -->|"1. DNS Query: backend.internal.corp"| DNSOperator
        DNSOperator -->|"2. Forward via spec.servers"| SecondaryDNS
        SecondaryDNS -->|"3. Returns Traefik ClusterIP VIP"| WorkloadPod
        WorkloadPod -->|"4. Direct TCP to Traefik VIP"| TraefikRouter
        TraefikRouter -->|"5. Proxies L7 Traffic"| TargetPod
    end

    classDef client fill:#343a40,stroke:#212529,stroke-width:2px,color:#fff,min-width:380px;
    classDef dns fill:#1864ab,stroke:#0b427a,stroke-width:2px,color:#fff,min-width:380px;
    classDef router fill:#d9480f,stroke:#a63207,stroke-width:2px,color:#fff,min-width:380px;
    classDef target fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:380px;

    class WorkloadPod client;
    class DNSOperator,SecondaryDNS dns;
    class TraefikRouter router;
    class TargetPod target;
```

</details>

#### Technical Breakdown: Step-by-Step Resolution Lifecycle

1. **Standard In-Pod Lookup**: The workload container executes standard POSIX `getaddrinfo` targeting `http://backend.internal.corp`. The query reaches the OpenShift default CoreDNS daemonset (`172.30.0.10:53`).
2. **Zone Forwarding Delegation**: The OpenShift DNS Operator evaluates the `spec.servers` stanza in `dns.operator.openshift.io/default`. Matching zone `internal.corp`, it forwards the UDP packet to `internal-dns-service.infra-dns:53`.
3. **In-Cluster CoreDNS Regex Rewrite**: The secondary CoreDNS pod parses the query, applies `rewrite name regex (.*)\.internal\.corp traefik.traefik-system.svc.cluster.local`, and synthesizes an authoritative `A` record containing Traefik's ClusterIP.
4. **Direct L4 Socket Establishment**: The client pod receives the Traefik ClusterIP and opens a direct TCP connection. The OpenShift OVN-Kubernetes SDN routes packets directly to Traefik pods without hitting the external ingress controller.
5. **L7 Policy Enforcement**: Traefik receives the HTTP payload, matches `Host(\`backend.internal.corp\`)`, executes attached middleware (rate limiting, headers, circuit breaking), and load balances across backend pods.

#### Analysis & Architectural Conclusions

* **OpenShift Operator Conformance**: By utilizing `spec.servers` zone forwarding, this pattern respects the OpenShift DNS Operator reconciliation loop. Upgrades from OCP 4.14 to 4.20+ will not overwrite or disrupt this configuration.
* **Security & Isolation**: The secondary CoreDNS runs unprivileged in user-space (`infra-dns` namespace) with `allowPrivilegeEscalation: false` and a read-only root filesystem, adhering to OpenShift `restricted-v2` SCC.
* **Recommended vs. Simplest**:
  - **Recommended**: **Yes, for Enterprise On-Premises OpenShift (Bare Metal, VMware)**. Provides 100% transparency for polyglot microservice fleets without requiring client-side configuration changes.
  - **Simplest**: Not the simplest to install (requires deploying secondary CoreDNS and patching the cluster operator), but operationally the simplest to consume for developers.

#### Step 1: Deploy In-Cluster Resolver (`deploys/traefik/openshift-dns-forwarder.yaml`)
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: infra-dns
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: internal-dns-corefile
  namespace: infra-dns
data:
  Corefile: |
    internal.corp:53 {
        errors
        log
        # Rewrite any *.internal.corp to Traefik ClusterIP
        rewrite name regex (.*)\.internal\.corp traefik.traefik-system.svc.cluster.local answer auto
        forward . 172.30.0.10
        cache 30
        reload
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: internal-dns-forwarder
  namespace: infra-dns
spec:
  replicas: 2
  selector:
    matchLabels:
      app: internal-dns-forwarder
  template:
    metadata:
      labels:
        app: internal-dns-forwarder
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: coredns
          image: registry.k8s.io/coredns/coredns:v1.11.3
          args: ["-conf", "/etc/coredns/Corefile"]
          volumeMounts:
            - name: config-volume
              mountPath: /etc/coredns
              readOnly: true
          ports:
            - name: dns-udp
              containerPort: 53
              protocol: UDP
            - name: dns-tcp
              containerPort: 53
              protocol: TCP
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
      volumes:
        - name: config-volume
          configMap:
            name: internal-dns-corefile
---
apiVersion: v1
kind: Service
metadata:
  name: internal-dns-service
  namespace: infra-dns
spec:
  type: ClusterIP
  ports:
    - name: dns-udp
      port: 53
      targetPort: 53
      protocol: UDP
    - name: dns-tcp
      port: 53
      targetPort: 53
      protocol: TCP
  selector:
    app: internal-dns-forwarder
```

#### Step 2: Configure OpenShift DNS Operator
Retrieve the ClusterIP of `internal-dns-service` and apply the patch to the OpenShift DNS Operator:

```bash
RESOLVER_IP=$(oc get svc internal-dns-service -n infra-dns -o jsonpath='{.spec.clusterIP}')

oc patch dns.operator.openshift.io/default --type=merge --patch "{
  \"spec\": {
    \"servers\": [
      {
        \"name\": \"internal-corp-forwarder\",
        \"zones\": [\"internal.corp\"],
        \"forwardPlugin\": {
          \"upstreams\": [\"${RESOLVER_IP}:53\"]
        }
      }
    ]
  }
}"
```
*Verification on OpenShift:*
```bash
oc get dns.operator.openshift.io/default -o yaml
oc exec -n lab-mesh deploy/frontend -- dig +short backend.internal.corp
# Returns the ClusterIP of Traefik!
```

---

### 2.3 OpenShift Pattern B: Pod-Level `hostAliases` & `dnsConfig` (Unprivileged)

When developers lack cluster-admin permissions to patch the OpenShift DNS Operator, configure static resolution or DNS overrides directly within workload Pod definitions:

<details>
<summary><b>Diagram 2.4: OpenShift Pattern B - Pod-Level hostAliases & dnsConfig (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    subgraph PatternB ["OpenShift Pattern B: Pod-Level hostAliases & dnsConfig (Unprivileged)"]
        Kubelet["<b>Node Kubelet Daemon</b><br/><br/>• Reads Pod spec.hostAliases definition<br/>• Mounts in-container /etc/hosts file<br/>• Maps 172.30.50.100 -> <b>backend.internal.corp</b>"]
        
        AppPod["<b>Application Container (consumer-app)</b><br/><br/>• Calls: <b>http://backend.internal.corp</b><br/>• glibc consults /etc/nsswitch.conf<br/>• 'files' entry evaluated BEFORE 'dns'!"]
        
        BypassedDNS["<b>OpenShift Cluster CoreDNS</b><br/><br/>• Service IP: 172.30.0.10:53 (Cluster DNS)<br/>🎯 <b>100% BYPASSED! Zero queries emitted.</b>"]
        
        TraefikSvc["<b>Traefik Router VIP (172.30.50.100)</b><br/><br/>• Direct TCP SYN Handshake from Pod<br/>• Matches IngressRoute Host: <b>backend.internal.corp</b><br/>• Executes attached Middleware Pipeline"]
        
        UpstreamApp["<b>Target Service Endpoints</b><br/><br/>• Workload pods (v1 / v2 Canary)<br/>• Receives Layer 7 Routed HTTP Traffic"]

        Kubelet -->|"1. Injects /etc/hosts"| AppPod
        AppPod -.->|"0% DNS queries (Bypassed)"| BypassedDNS
        AppPod -->|"2. Direct TCP connection"| TraefikSvc
        TraefikSvc -->|"3. Proxies L7 Traffic"| UpstreamApp
    end

    classDef client fill:#343a40,stroke:#212529,stroke-width:2px,color:#fff,min-width:380px;
    classDef dns fill:#1864ab,stroke:#0b427a,stroke-width:2px,color:#fff,min-width:380px;
    classDef router fill:#d9480f,stroke:#a63207,stroke-width:2px,color:#fff,min-width:380px;
    classDef target fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:380px;
    classDef bypassed fill:#868e96,stroke:#495057,stroke-dasharray: 5 5,color:#fff,min-width:380px;

    class AppPod client;
    class Kubelet dns;
    class BypassedDNS bypassed;
    class TraefikSvc router;
    class UpstreamApp target;
```

</details>

#### Technical Breakdown: The `/etc/nsswitch.conf` Local Override

* **POSIX Name Service Switch**: Standard Linux container runtimes (glibc/musl) consult `/etc/nsswitch.conf`, configured by default as `hosts: files dns`.
* **Kubelet In-Memory Injection**: Kubelet populates `/etc/hosts` in the container's root filesystem based on `spec.hostAliases`.
* **Zero Network Traffic**: When the application process calls `getaddrinfo("backend.internal.corp")`, the resolver finds the match in `/etc/hosts` immediately. No UDP packet leaves the pod network interface, and CoreDNS is completely bypassed.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: consumer-app
  namespace: production
spec:
  template:
    spec:
      # Option 1: Static IP mapping to Traefik ClusterIP
      hostAliases:
        - ip: "172.30.50.100" # Traefik Service ClusterIP
          hostnames:
            - "backend.internal.corp"
            - "api.payments.corp"
      # Option 2: Custom DNS Search Domain
      dnsConfig:
        searches:
          - internal.corp
          - lab-traefik.svc.cluster.local
        options:
          - name: ndots
            value: "2"
```

#### Analysis & Architectural Conclusions

* **Permissions & Blast Radius**: Requires strictly developer-level tenant namespace permissions. Zero cluster-admin access is required, and there is zero blast radius on the rest of the cluster's DNS infrastructure.
* **Maintenance & Scalability Limitations**: Statically hardcoding ClusterIPs into workload manifests violates 12-factor application architecture. If the ingress service is deleted and recreated, its ClusterIP changes, breaking all consuming client pods.
* **Recommended vs. Simplest**:
  - **Simplest**: **Yes! For individual non-admin developers and staging tests**. It requires zero cluster permissions, zero secondary pods, and zero operator configurations.
  - **Recommended**: **No for production**. Prohibited for production microservices due to maintenance toil and lack of dynamic IP failover.

---

### 2.4 Vanilla Kubernetes, Kind & SUSE RKE2: CoreDNS `rewrite` Plugin

In vanilla Kubernetes clusters (including Kind, K3s, kubeadm, and RKE2), CoreDNS is directly configurable via the `Corefile` in the `kube-system/coredns` ConfigMap:

<details>
<summary><b>Diagram 2.5: Vanilla Kubernetes / Kind / RKE2 CoreDNS rewrite Plugin (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    subgraph VanillaK8s ["Vanilla Kubernetes / Kind / RKE2: Native CoreDNS rewrite Plugin"]
        PodV["<b>Workload Client Pod</b><br/><br/>• Calls: <b>http://backend.internal.corp</b><br/>• Standard UDP:53 query to CoreDNS<br/>• Zero client-side configuration needed"]
        
        CoreDNS_Engine["<b>CoreDNS Engine (kube-system)</b><br/><br/>• Evaluates Corefile plugins in-memory<br/>• Plugin: <code>rewrite name regex (.*).internal.corp</code><br/>• Maps query to: <b>traefik.traefik-system.svc</b>"]
        
        K8s_Plugin["<b>CoreDNS kubernetes Plugin</b><br/><br/>• Resolves traefik.traefik-system.svc<br/>• Synthesizes authoritative A record response<br/>• Returns Traefik ClusterIP VIP to Pod"]
        
        Traefik_Vanilla["<b>Traefik Edge / Ingress Gateway</b><br/><br/>• IngressRoute / HTTPRoute Host matching<br/>• Enforces middlewares & Canary traffic splits<br/>• Forwarding to backend endpoints"]

        PodV -->|"1. Query: backend.internal.corp"| CoreDNS_Engine
        CoreDNS_Engine -->|"2. Regex rewrite in-memory"| K8s_Plugin
        K8s_Plugin -->|"3. Synthesized A Record (VIP)"| PodV
        PodV -->|"4. Direct TCP to Traefik VIP"| Traefik_Vanilla
    end

    classDef client fill:#343a40,stroke:#212529,stroke-width:2px,color:#fff,min-width:380px;
    classDef dns fill:#1864ab,stroke:#0b427a,stroke-width:2px,color:#fff,min-width:380px;
    classDef router fill:#d9480f,stroke:#a63207,stroke-width:2px,color:#fff,min-width:380px;

    class PodV client;
    class CoreDNS_Engine,K8s_Plugin dns;
    class Traefik_Vanilla router;
```

</details>

#### Technical Breakdown: In-Memory CoreDNS Rewriting

* **Single-Hop Plugin Execution**: CoreDNS evaluates plugins in order. When the `rewrite` plugin matches `(.*)\.internal\.corp`, it alters the request name internally before handing it to the downstream `kubernetes` plugin.
* **Auto Response Generation**: The `answer auto` parameter informs CoreDNS to rewrite the query back in the response answer section, preventing DNS resolution failure on strict client stub resolvers.
* **Zero Additional Pods**: Runs inside existing `kube-system/coredns` pods with zero additional latency and zero extra cluster resource consumption.

```corefile
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        # Direct regex rewrite of corporate FQDNs to Traefik ClusterIP
        rewrite name regex (.*)\.internal\.corp traefik.traefik-system.svc.cluster.local answer auto
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
        }
        forward . /etc/resolv.conf
        cache 30
        reload
        loadbalance
    }
```

#### Analysis & Architectural Conclusions (Vanilla Kubernetes / Kind / RKE2)

* **Performance & Simplicity**: In unmanaged distributions, editing the `Corefile` directly is both the most performant and architecturally simplest mechanism.
* **Failure Blast Radius**: If the Corefile contains syntax errors, CoreDNS will fail to reload, impacting all cluster DNS lookups. Always validate configuration syntax before applying.
* **Recommended vs. Simplest**:
  - **Both Recommended and Simplest**: For vanilla Kubernetes, Kind, Minikube, K3s, and RKE2.

---

### 2.5 Managed Cloud Distributions (AWS EKS, Azure AKS, Google Cloud GKE)

In hyperscaler-managed Kubernetes offerings, cluster DNS is managed as a platform add-on. Modifying the main Corefile directly will lead to drift or overwrite during cluster control-plane upgrades. Providers expose designated extension mechanisms:

<details>
<summary><b>Diagram 2.6: Managed Cloud Distributions - EKS / AKS coredns-custom vs. GKE Cloud DNS (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    subgraph ManagedCloudPlane ["Managed Cloud Distributions: Native CoreDNS Extension & Interception"]
        subgraph EKSAKSPlane ["AWS EKS & Azure AKS (coredns-custom Pattern)"]
            ClientEKS["<b>EKS / AKS Workload Pod</b><br/><br/>• Queries: <b>backend.internal.corp</b><br/>• Standard UDP:53 in-pod query<br/>• Zero client modifications"]
            
            CustomCM["<b>coredns-custom ConfigMap</b><br/><br/>• Overrides internal.server block<br/>• Plugin: <code>rewrite name regex (.*).internal.corp -> traefik.svc</code><br/>• Survives AWS & Azure managed add-on upgrades"]
            
            ManagedCoreDNS["<b>Managed CoreDNS Daemon</b><br/><br/>• Automatically imports custom blocks<br/>• Resolves Traefik Service ClusterIP VIP<br/>• Returns VIP to EKS/AKS Client Pod"]

            ClientEKS -->|"1. DNS Query"| CustomCM
            CustomCM -->|"2. Evaluates Plugin"| ManagedCoreDNS
            ManagedCoreDNS -->|"3. Returns Traefik VIP"| ClientEKS
        end

        EKSAKSPlane ~~~ GKEPlane

        subgraph GKEPlane ["Google Cloud GKE (Cloud DNS vs. kube-dns stubDomains)"]
            ClientGKE["<b>GKE Workload Pod</b><br/><br/>• Queries: <b>backend.internal.corp</b><br/>• Targets Google Cloud infrastructure"]
            
            GKEPathA["<b>GCP Cloud DNS (VPC-Native)</b><br/><br/>• Private Hosted Zone: <b>internal.corp</b><br/>• High-availability Cloud Anycast VIP<br/>• 0MB in-cluster DNS memory footprint"]
            
            GKEPathB["<b>kube-dns stubDomains (Legacy)</b><br/><br/>• ConfigMap: kube-system/kube-dns<br/>• Forwards upstream to Traefik ClusterIP"]

            ClientGKE -->|"Recommended: VPC Anycast Scope"| GKEPathA
            ClientGKE -.->|"Alternative: In-Cluster Forward"| GKEPathB
        end
    end

    classDef client fill:#343a40,stroke:#212529,stroke-width:2px,color:#fff,min-width:380px;
    classDef dns fill:#1864ab,stroke:#0b427a,stroke-width:2px,color:#fff,min-width:380px;
    classDef cloud fill:#087f5b,stroke:#0b6246,stroke-width:2px,color:#fff,min-width:380px;

    class ClientEKS,ClientGKE client;
    class CustomCM,ManagedCoreDNS,GKEPathB dns;
    class GKEPathA cloud;
```

</details>

#### Technical Breakdown: Provider-Native Extension Points

* **AWS EKS (`coredns-custom`)**: EKS CoreDNS Corefile contains an `import /etc/coredns/custom/*.server` directive. Creating the `coredns-custom` ConfigMap automatically injects the server block without modifying the base managed add-on.
* **Azure AKS (`coredns-custom`)**: AKS CoreDNS similarly imports `/etc/coredns/custom/*.server` and `*.override`. Changes persist across cluster version upgrades.
* **Google Cloud GKE**: GKE offers two modes: managed `kube-dns` with `stubDomains` for in-cluster forwarding, or VPC-native **Cloud DNS for GKE**, which offloads cluster DNS to Google Cloud DNS anycast resolvers, entirely eliminating CoreDNS pods.

### 2.5.1 Amazon EKS: `coredns-custom` ConfigMap

Amazon EKS manages the `coredns` deployment but supports persistent customer overrides via a ConfigMap named `coredns-custom` in `kube-system`. This survives managed EKS add-on updates:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
  labels:
    eks.amazonaws.com/component: coredns
    k8s-app: kube-dns
data:
  internal.server: |
    internal.corp:53 {
        errors
        log
        rewrite name regex (.*)\.internal\.corp traefik.traefik-system.svc.cluster.local answer auto
        forward . /etc/resolv.conf
        cache 30
    }
```
Apply and restart CoreDNS pods:
```bash
kubectl apply -f coredns-custom.yaml
kubectl rollout restart deployment/coredns -n kube-system
```

---

### 2.5.2 Microsoft Azure AKS: `coredns-custom` ConfigMap

Azure Kubernetes Service (AKS) also provides custom CoreDNS plug points via `coredns-custom` in `kube-system`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  internal.server: |
    internal.corp:53 {
        errors
        rewrite name regex (.*)\.internal\.corp traefik.traefik-system.svc.cluster.local answer auto
        forward . /etc/resolv.conf
    }
```

---

### 2.5.3 Google Cloud GKE: Cloud DNS & Kube-DNS Stub Domains

In GKE, if using standard Kube-DNS / CoreDNS, configure the `kube-dns` ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
data:
  stubDomains: |
    {"internal.corp": ["10.96.120.45"]} # Points to internal CoreDNS / Traefik IP
```
*Note: If GKE Cloud DNS is enabled (VPC scope), add a Cloud DNS private zone in GCP Cloud Console or Terraform mapping `internal.corp` to the Traefik internal load balancer IP.*

#### Analysis & Architectural Conclusions (Managed Cloud Distributions)

* **Upgrade Safety**: Both EKS and AKS `coredns-custom` patterns are officially supported by AWS and Azure, guaranteeing zero configuration loss during automated cluster upgrades.
* **GKE High-Scale Recommendation**: In GKE, enabling **Cloud DNS for GKE** is strongly recommended over `kube-dns` stub domains for clusters running >500 pods to avoid CoreDNS memory exhaustion.
* **Recommended vs. Simplest**:
  - **AWS EKS & Azure AKS**: `coredns-custom` is **Both Recommended and Simplest**.
  - **Google Cloud GKE**: **Cloud DNS Private Zones** is **Recommended** (managed cloud SLA, zero in-cluster memory overhead); `kube-dns` `stubDomains` is **Simplest** for rapid local proof-of-concept testing.

---

## 3. Traefik v3 Implementation (without Traefik Mesh)

Once DNS is routed to Traefik, Traefik functions as an **East-West Internal Gateway** using native `IngressRoute` and `Middleware` definitions without needing sidecar injection.

<details>
<summary><b>Diagram 3.1: Traefik v3 Dual-Plane L7 Router & Middleware Pipeline (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    subgraph TraefikDualPlane ["Traefik v3 Dual-Plane L7 Router & Middleware Pipeline"]
        subgraph EntryPoints ["Traffic Ingress EntryPoints"]
            EP_Internal["<b>Internal East-West (web)</b><br/><br/>• Port :8000 / Cleartext or mTLS<br/>• In-cluster microservice hairpin"]
            EP_External["<b>External North-South (websecure)</b><br/><br/>• Port :8443 / TLS 1.3 Termination<br/>• Corporate / Public SAN certs"]
        end

        subgraph IngressRouteTier ["Traefik IngressRoute Rule Matching"]
            RouterMatch["<b>Rule Match Engine</b><br/><br/>• Host: <b>backend.internal.corp</b><br/>• PathPrefix: <b>/api</b>"]
        end

        subgraph MiddlewarePipeline ["Enterprise Middleware Execution Chain"]
            MW_RateLimit["<b>1. edge-rate-limit</b><br/><br/>• Token-bucket: avg 25, burst 50"]
            MW_SecHeaders["<b>2. security-headers</b><br/><br/>• HSTS, FrameOptions, CSP headers"]
            MW_CircuitBreaker["<b>3. internal-circuit-breaker</b><br/><br/>• Tripped if Latency > 150ms || Err > 15%"]
            
            MW_RateLimit --> MW_SecHeaders --> MW_CircuitBreaker
        end

        subgraph UpstreamCanary ["Canary Weighted Service Delivery"]
            SvcV1["<b>backend-v1 (Stable)</b><br/><br/>• Weight: 90% Traffic Allocation"]
            SvcV2["<b>backend-v2 (Canary)</b><br/><br/>• Weight: 10% Traffic Allocation"]
        end

        EP_Internal --> RouterMatch
        EP_External --> RouterMatch
        RouterMatch --> MW_RateLimit
        MW_CircuitBreaker -->|"90% Traffic"| SvcV1
        MW_CircuitBreaker -->|"10% Traffic"| SvcV2
    end

    classDef ep fill:#343a40,stroke:#212529,stroke-width:2px,color:#fff,min-width:340px;
    classDef router fill:#d9480f,stroke:#a63207,stroke-width:2px,color:#fff,min-width:340px;
    classDef mw fill:#e67700,stroke:#b05b00,stroke-width:2px,color:#fff,min-width:340px;
    classDef target fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:340px;

    class EP_Internal,EP_External ep;
    class RouterMatch router;
    class MW_RateLimit,MW_SecHeaders,MW_CircuitBreaker mw;
    class SvcV1,SvcV2 target;
```

</details>

#### Technical Breakdown: The Dual-Plane Execution Flow

* **Unified EntryPoints**: Traefik binds internal and external ports within the same daemon. East-West requests arrive over port 8000 (`web`) while external TLS traffic arrives over port 8443 (`websecure`).
* **Composable Middleware Pipeline**: Traefik runs chained Go middleware plugins sequentially in memory without inter-process IPC:
  1. `edge-rate-limit`: Enforces token-bucket throughput limiting per client IP.
  2. `security-headers`: Injects CSP, X-Content-Type-Options, and CORS controls.
  3. `internal-circuit-breaker`: Monitors moving-window metrics and opens the circuit when latency exceeds 150ms or network errors exceed 15%.
* **Canary Traffic Shifting**: Traefik natively distributes requests across `backend-v1` (90%) and `backend-v2` (10%) without requiring synthetic sidecar proxies.

### 3.1 Traefik Dual-Plane IngressRoute (`deploys/traefik/ingressroute-fqdn.yaml`)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: fqdn-internal-external-route
  namespace: lab-traefik
spec:
  entryPoints:
    - web        # Internal East-West (Port 8000)
    - websecure   # External North-South (Port 8443)
  routes:
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
        - name: internal-circuit-breaker
```

### 3.2 Enterprise Middleware Pipeline

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: edge-rate-limit
  namespace: lab-traefik
spec:
  rateLimit:
    average: 25
    burst: 50
    period: 1s
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: internal-circuit-breaker
  namespace: lab-traefik
spec:
  circuitBreaker:
    expression: "LatencyAtQuantileMS(50.0) > 150 || NetworkErrorRatio() > 0.15"
```

#### Analysis & Architectural Conclusions (Traefik Dual-Plane)

* **Sidecarless Efficiency**: Eliminates the 50–100MB RAM tax per workload pod and eliminates 2 out of 4 network hops per call compared to traditional sidecar meshes.
* **Operational Trade-Off**: Hairpinning internal microservice traffic through an ingress controller introduces a centralized intermediary. Traefik must be scaled with Horizontal Pod Autoscalers (HPA) and anti-affinity rules to prevent bottlenecking.
* **Recommended vs. Simplest**:
  - **Both Recommended and Simplest**: For application teams wanting enterprise Layer 7 API governance (rate limiting, canary rollouts, auth, circuit breaking) on internal East-West traffic without taking on the operational complexity of a full service mesh.

---

## 4. Mesh-Native Transparent DNS (Zero CoreDNS Alterations)

The most elegant architectural breakthrough of modern meshes like **Cilium eBPF** and **Istio Ambient** is that **they completely eliminate the need to modify cluster DNS operators or CoreDNS!**

### 4.1 Cilium eBPF: In-Kernel DNS Proxy & `toFQDNs` Egress Policies

Cilium attaches eBPF programs to the pod's cgroup socket layer. When a container sends a DNS request, Cilium intercepts it transparently at the kernel layer, inspects FQDN rules, and builds in-kernel ipsets:

<details>
<summary><b>Diagram 4.1: Cilium eBPF In-Kernel DNS Interception & toFQDNs Security (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    subgraph CiliumEBPF ["Cilium eBPF: In-Kernel DNS Interception & toFQDNs Security"]
        PodCilium["<b>Workload Client Pod</b><br/><br/>• Calls: <b>api.payments.internal.corp</b><br/>• Standard UDP/TCP :53 query from pod<br/>• Zero client or proxy sidecar overhead"]
        
        KernelHook["<b>Linux Kernel Socket Layer</b><br/><br/>• Attached to cgroup2 BPF_PROG_TYPE_SOCK_OPS<br/>• Intercepts connect/sendto socket syscalls<br/>• Zero userspace context switch"]
        
        CiliumDNSProxy["<b>Cilium In-Kernel DNS Proxy</b><br/><br/>• Evaluates toFQDNs egress network policy<br/>• Pattern match: <b>payments.internal.corp</b><br/>• Forwards query to upstream cluster DNS"]
        
        EBPF_IPMap["<b>In-Kernel eBPF Dynamic Cache</b><br/><br/>• Extracts IPs from DNS answer dynamically<br/>• Updates kernel map: <b>cilium_ipcache</b><br/>• Automatically grants egress for ports :443/:8080"]
        
        EgressTarget["<b>Target Service Destination</b><br/><br/>• Wire-speed direct socket delivery<br/>• Sub-millisecond latency (&lt;0.15ms)<br/>• Enforces cryptographically verified egress"]

        PodCilium -->|"1. DNS Request :53"| KernelHook
        KernelHook -->|"2. Kernel eBPF redirect"| CiliumDNSProxy
        CiliumDNSProxy -->|"3. Policy verified & IPs cached"| EBPF_IPMap
        EBPF_IPMap -->|"4. Returns IP answer to Pod"| PodCilium
        PodCilium -->|"5. Line-rate TCP Connection"| EgressTarget
    end

    classDef client fill:#343a40,stroke:#212529,stroke-width:2px,color:#fff,min-width:380px;
    classDef hook fill:#0c8599,stroke:#085461,stroke-width:2px,color:#fff,min-width:380px;
    classDef agent fill:#1864ab,stroke:#0b427a,stroke-width:2px,color:#fff,min-width:380px;
    classDef map fill:#d9480f,stroke:#a63207,stroke-width:2px,color:#fff,min-width:380px;
    classDef target fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:380px;

    class PodCilium client;
    class KernelHook hook;
    class CiliumDNSProxy agent;
    class EBPF_IPMap map;
    class EgressTarget target;
```

</details>

#### Technical Breakdown: In-Kernel DNS Redirection & IP Cache

* **cgroup Socket Interception**: When the container invokes `connect(2)` or `sendto(2)` targeting port 53, the eBPF `sock_ops` program intercepts the socket syscall in kernel space, redirecting UDP/TCP datagrams to the node-local Cilium DNS proxy.
* **Dynamic FQDN-to-IP Binding**: When the response arrives, the Cilium proxy parses the `A`/`AAAA` answers and updates the in-kernel eBPF ipcache map (`cilium_ipcache`).
* **Line-Rate Enforcement**: Future TCP connections to those dynamically discovered IPs bypass userspace proxies entirely. The kernel enforces security policy directly on the socket layer at near line rate (<0.15ms latency).

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: fqdn-zero-trust-egress
  namespace: lab-cilium
spec:
  endpointSelector:
    matchLabels:
      app: backend
  egress:
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

#### Analysis & Architectural Conclusions (Cilium eBPF)

* **Elimination of DNS Bottlenecks**: CoreDNS is completely relieved from high-frequency egress policy evaluations. DNS responses are cached in the kernel, eliminating CoreDNS as an egress bottleneck.
* **Ephemeral Cloud IP Handling**: Because SaaS IPs (Stripe, Okta, AWS) change dynamically, static CIDR NetworkPolicies are impractical. Cilium's `toFQDNs` dynamically tracks DNS TTLs and updates the kernel ipcache automatically.
* **Recommended vs. Simplest**:
  - **Recommended**: **Yes, for high-throughput, low-latency microservices and strict zero-trust egress auditing (PCI-DSS / ISO 27001)**.
  - **Simplest**: If Cilium is already installed as the cluster CNI, writing a `toFQDNs` policy is **Simplest** because it requires zero DNS forwarders, zero Corefile mutations, and zero application changes.

---

### 4.2 Istio Ambient: Node-Level ztunnel DNS Capture & `ServiceEntry`

In Istio Ambient, DNS proxying is built into the node-level **`ztunnel`** (`ISTIO_META_DNS_CAPTURE=true`). When an internal pod requests `backend.internal.corp`:

<details>
<summary><b>Diagram 4.2: Istio Ambient Node ztunnel DNS Capture & ServiceEntry VIP Synthesis (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    subgraph IstioAmbientDNS ["Istio Ambient: Node ztunnel DNS Capture & ServiceEntry VIP Synthesis"]
        PodAmbient["<b>Workload Pod in Ambient Mesh</b><br/><br/>• Calls: <b>http://backend.internal.corp</b><br/>• Standard UDP:53 in-pod DNS query<br/>• Zero sidecar proxy in workload pod"]
        
        ZtunnelDNS["<b>Node ztunnel (DNS Capture Engine)</b><br/><br/>• Intercepts node port 53 via eBPF/iptables<br/>• Matches ServiceEntry Host definition<br/>• Synthesizes VIP: <b>240.240.0.100</b><br/>🎯 <b>Cluster CoreDNS 100% BYPASSED!</b>"]
        
        HBONETunnel["<b>ztunnel HBONE Encapsulation</b><br/><br/>• Pod opens TCP: 240.240.0.100:8080<br/>• Wraps stream in HBONE tunnel (Port :15008)<br/>• Enforces SPIFFE cryptographic mTLS identity"]
        
        WaypointProxy["<b>Namespace Waypoint Envoy Proxy</b><br/><br/>• Terminates HBONE mTLS tunnel connection<br/>• Evaluates Gateway API HTTPRoute rules<br/>• Splits: 90% v1 / 10% v2 canary traffic"]
        
        TargetAmbient["<b>Target Service Endpoints</b><br/><br/>• Upstream workloads (v1 / v2 Canary)<br/>• Receives authenticated Layer 7 HTTP traffic"]

        PodAmbient -->|"1. DNS Query :53"| ZtunnelDNS
        ZtunnelDNS -->|"2. Synthesizes VIP: 240.240.0.100"| PodAmbient
        PodAmbient -->|"3. TCP to 240.240.0.100:8080"| HBONETunnel
        HBONETunnel -->|"4. HBONE mTLS (Port 15008)"| WaypointProxy
        WaypointProxy -->|"5. Proxies L7 Traffic"| TargetAmbient
    end

    classDef client fill:#343a40,stroke:#212529,stroke-width:2px,color:#fff,min-width:380px;
    classDef ztunnel fill:#1864ab,stroke:#0b427a,stroke-width:2px,color:#fff,min-width:380px;
    classDef tunnel fill:#0c8599,stroke:#085461,stroke-width:2px,color:#fff,min-width:380px;
    classDef waypoint fill:#d9480f,stroke:#a63207,stroke-width:2px,color:#fff,min-width:380px;
    classDef target fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:380px;

    class PodAmbient client;
    class ZtunnelDNS ztunnel;
    class HBONETunnel tunnel;
    class WaypointProxy waypoint;
    class TargetAmbient target;
```

</details>

#### Technical Breakdown: The Sidecarless DNS Capture Pipeline

1. **Local Node DNS Capture**: With `ISTIO_META_DNS_CAPTURE=true`, `ztunnel` uses eBPF/iptables redirection on the node to intercept port 53 UDP/TCP traffic before it leaves the node network interface.
2. **Synthetic Virtual VIP (`240.240.0.0/16`)**: If the query matches an Istio `ServiceEntry` host (`backend.internal.corp`), `ztunnel` returns an internally synthesized non-routable IP address (`240.240.0.100`). The cluster CoreDNS daemon is never queried.
3. **HBONE Tunneling to Waypoint**: When the application transmits TCP packets to `240.240.0.100:8080`, `ztunnel` captures the connection, initiates an mTLS HBONE tunnel on port 15008, and routes it to the target namespace's `waypoint` proxy.
4. **Gateway API Routing**: The `waypoint` proxy inspects the HTTP request, matches the `HTTPRoute` rules matching `hostnames: ["backend.internal.corp"]`, and balances traffic across the real endpoint pods.
5. **Full OpenShift 4.20+ Immunity**: Because DNS capture and VIP synthesis occur at the node layer in `ztunnel`, **zero OpenShift DNS Operator configuration or Corefile customization is required**.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: internal-backend-fqdn
  namespace: lab-istio
spec:
  hosts:
    - backend.internal.corp
  addresses:
    - 240.240.0.100 # Synthesized Virtual VIP
  ports:
    - number: 8080
      name: http-api
      protocol: HTTP
  resolution: STATIC
  endpoints:
    - address: backend-v1.lab-istio.svc.cluster.local
      ports:
        http-api: 8080
---
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

#### Analysis & Architectural Conclusions (Istio Ambient)

* **OpenShift Operator Immutability Solution**: Solves the OpenShift DNS Operator immutability barrier natively at Layer 4 without needing cluster-admin access to patch DNS operators or maintain forwarder pods.
* **Sidecarless Resource Savings**: By sharing a single `ztunnel` per node and a single `waypoint` proxy per namespace, clusters save 80% RAM compared to traditional sidecar deployments while enforcing full zero-trust mTLS.
* **Recommended vs. Simplest**:
  - **Recommended**: **Yes, for Enterprise Zero-Trust Service Mesh on Red Hat OpenShift 4.20+ (OpenShift Service Mesh 3.x)**. Provides transparent FQDN resolution, cryptographic SPIFFE identity, and Gateway API conformance.
  - **Simplest**: If Istio Ambient is already active, adding a `ServiceEntry` is **Simplest** compared to managing OpenShift DNS operator forwarders or secondary CoreDNS pods.

---

## 5. Comprehensive Distribution Comparison Matrix

| Distribution / Engine | DNS Operator Type | CoreDNS Immutability | Supported East-West FQDN Interception Mechanism | Operator Privileges Required? |
| :--- | :--- | :--- | :--- | :--- |
| **Red Hat OpenShift (4.14 – 4.20+)** | OpenShift DNS Operator (`dns.operator.openshift.io`) | **Strictly Immutable** (Reconciled) | `DNS.operator.openshift.io/default` zone forwarding to in-cluster secondary CoreDNS forwarder (`infra-dns`), or pod `hostAliases` | **Yes** (Cluster Admin for DNS operator patch; None for `hostAliases`) |
| **Vanilla Kubernetes / Kind / RKE2** | Standard CoreDNS | **Mutable** | Direct `Corefile` modification with `rewrite` plugin | **Yes** (Cluster Admin) |
| **Amazon EKS** | Managed CoreDNS Add-On | Semi-Managed | `coredns-custom` ConfigMap (`internal.server` / `*.override`) | **Yes** (`kube-system` write access) |
| **Microsoft Azure AKS** | Managed CoreDNS | Semi-Managed | `coredns-custom` ConfigMap (`internal.server`) | **Yes** (`kube-system` write access) |
| **Google Cloud GKE** | Kube-DNS / Cloud DNS | Managed | `kube-dns` ConfigMap `stubDomains` or GCP Cloud DNS Private Zone | **Yes** (GCP IAM or `kube-system`) |
| **Cilium eBPF (Any Distro / OCP)** | Cilium CNI Agent | **Bypasses CoreDNS** | In-kernel eBPF socket interception & dynamic `toFQDNs` ipsets | None on CoreDNS; Cilium CNI privilege |
| **Istio Ambient (Any Distro / OCP)** | `ztunnel` DaemonSet | **Bypasses CoreDNS** | Node `ztunnel` DNS capture (`ISTIO_META_DNS_CAPTURE`) + `ServiceEntry` | None on CoreDNS; standard Mesh onboarding |

---

## 6. Use-Case Decision Matrix: Recommended vs. Simplest Pattern

Choosing the correct FQDN interception and routing pattern depends fundamentally on **three architectural variables**:
1. **Cluster Distribution & Operator Governance** (OpenShift DNS Operator vs. Managed EKS/AKS/GKE vs. Vanilla K8s).
2. **Administrative Privileges** (`cluster-admin` vs. unprivileged namespace developer).
3. **Application Ergonomics** (Transparent FQDN calling vs. synthetic HTTP Host header injection vs. Mesh-native capture).

### 6.1 Enterprise Master Decision Flowchart

<details>
<summary><b>Diagram 6.1: Enterprise Master FQDN Routing Decision Flowchart (Click to Expand / Collapse)</b></summary>

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "nodeSpacing": 45, "rankSpacing": 45}}}%%
flowchart TD
    Start(["<b>Select Enterprise FQDN Routing Pattern</b>"]) --> DistroCheck{{"<b>What is your Kubernetes Distribution?</b>"}}

    DistroCheck -->|"Red Hat OpenShift (4.14 - 4.20+)"| OCPCheck{{"<b>Cluster-Admin Rights & Scope?</b>"}}
    DistroCheck -->|"Vanilla K8s / Kind / RKE2"| DecVanilla["<b>CoreDNS rewrite Plugin</b><br/><br/>• <b>Recommended & Simplest</b><br/>• In-memory Corefile regex rewrite<br/>• Zero secondary resolver pods"]
    DistroCheck -->|"AWS EKS or Azure AKS"| DecEKSAKS["<b>coredns-custom ConfigMap</b><br/><br/>• <b>Recommended & Simplest</b><br/>• Survives managed add-on upgrades<br/>• Native cloud provider extension"]
    DistroCheck -->|"Google Cloud GKE"| DecGKE["<b>GCP Cloud DNS Private Zone</b><br/><br/>• <b>Recommended:</b> VPC Cloud DNS<br/>• <b>Simplest:</b> kube-dns stubDomains<br/>• Offloads DNS to Cloud Anycast"]
    DistroCheck -->|"Zero-Trust Mesh Active"| MeshCheck{{"<b>Mesh Data Plane Architecture?</b>"}}

    OCPCheck -->|"Admin + Transparent URLs"| DecPatternA["<b>OpenShift Pattern A (Forwarder)</b><br/><br/>• <b>Recommended for On-Premises OCP</b><br/>• DNS spec.servers -> infra-dns CoreDNS<br/>• 100% transparent client calling"]
    OCPCheck -->|"No Admin or AWS ROSA Cluster"| DecApproachB["<b>Split-Horizon Ingress via Traefik</b><br/><br/>• <b>Simplest for OCP & Rec for ROSA</b><br/>• Call traefik.svc + HTTP Host Header<br/>• Zero forwarders or operator patches"]
    OCPCheck -->|"Tenant Dev / Rapid Testing"| DecPatternB["<b>Pod-Level hostAliases</b><br/><br/>• <b>Simplest for Ad-hoc Testing</b><br/>• 0% Admin rights, 0% CoreDNS load<br/>• ⚠️ Anti-pattern for production"]

    MeshCheck -->|"Cilium eBPF CNI"| DecCilium["<b>Cilium In-Kernel DNS Proxy (toFQDNs)</b><br/><br/>• <b>Recommended for Ultra-Low Latency</b><br/>• Intercepts cgroup socket (&lt;0.15ms)<br/>• Dynamic IP cache for SaaS egress"]
    MeshCheck -->|"Istio Ambient Mode"| DecAmbient["<b>Istio Ambient ztunnel + ServiceEntry</b><br/><br/>• <b>Recommended for OCP 4.20+ Mesh</b><br/>• Synthesized 240.240.0.0/16 VIP<br/>• HBONE mTLS tunnel to Waypoint Envoy"]

    classDef start fill:#1864ab,stroke:#0b427a,stroke-width:2px,color:#fff,min-width:340px;
    classDef check fill:#e67700,stroke:#b05b00,stroke-width:2px,color:#fff,min-width:340px;
    classDef rec fill:#2b8a3e,stroke:#1b5727,stroke-width:2px,color:#fff,min-width:340px;
    classDef warn fill:#d9480f,stroke:#a63207,stroke-width:2px,color:#fff,min-width:340px;

    class Start start;
    class DistroCheck,OCPCheck,MeshCheck check;
    class DecVanilla,DecEKSAKS,DecGKE,DecPatternA,DecApproachB,DecCilium,DecAmbient rec;
    class DecPatternB warn;
```

</details>

#### Flowchart Decision Guidance

* **Step 1: Check Distribution Type**: Identify if the cluster enforces DNS operator immutability (OpenShift) or permits direct/custom ConfigMap overrides (Vanilla K8s, EKS, AKS, GKE).
* **Step 2: Check Privileges & Operational Authority**: If running OpenShift without `cluster-admin` access, select **Approach B (Split-Horizon Ingress via Traefik Service)**. If `cluster-admin` is available and client code cannot be modified, deploy **Pattern A (Zone Forwarding)**.
* **Step 3: Check Active Service Mesh**: If Cilium eBPF or Istio Ambient is already active, completely bypass CoreDNS and leverage kernel or node-level DNS proxying (`toFQDNs` or `ServiceEntry`).

---

### 6.2 Granular Use-Case Evaluation: Recommended vs. Simplest

| Enterprise Use Case | Recommended Architecture | Simplest Architecture | Why Recommended? | Why Simplest? | Operational Trade-off & Blast Radius |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1. On-Premises OpenShift (4.14 – 4.20+)** | **Pattern A: DNS Operator Zone Forwarding** to secondary CoreDNS (`infra-dns`) | **Pattern B: Pod-Level `hostAliases`** (for testing) or **Approach B** (for services) | Provides 100% transparent URLs (`http://backend.internal.corp`) across all namespaces; zero client code alterations. Conforms to OpenShift operator reconciliation. | Pattern B requires zero infrastructure; Approach B requires zero DNS operator patches. | Pattern A introduces a secondary deployment (`infra-dns`) to monitor and patch. Pattern B causes manifest configuration sprawl. |
| **2. AWS ROSA / OpenShift on AWS** | **Approach B: Split-Horizon Ingress via Traefik Service** (`traefik-fqdn-poc`) | **Approach B: Split-Horizon Ingress via Traefik Service** | **Both Recommended and Simplest**. Bypasses DNS Operator completely. Combines native OpenShift CoreDNS with Traefik mTLS and AWS Route 53 private hosted zones. | Zero CoreDNS modifications, zero secondary resolver pods, zero cluster-admin permissions needed on ROSA. | Microservices must target Traefik's `svc.cluster.local` and supply the business FQDN in the `Host` header. |
| **3. OpenShift Developer (Zero Admin Rights)** | **Approach B: Split-Horizon Ingress via Traefik Service** | **Pattern B: Pod-Level `hostAliases`** | Approach B provides dynamic DNS resolution and automated mTLS routing without hardcoded IP addresses. | Developer simply adds `hostAliases` directly into their Deployment YAML; immediate effect with zero external dependencies. | Pattern B breaks if Traefik service is recreated with a new ClusterIP. Approach B requires adding Host headers or configuring an HTTP client proxy. |
| **4. Vanilla Kubernetes / Kind / RKE2** | **CoreDNS `rewrite` Plugin** in `kube-system/coredns` | **CoreDNS `rewrite` Plugin** in `kube-system/coredns` | **Both Recommended and Simplest**. In-memory single-hop regex rewrite executed directly by CoreDNS at wire speed with 0ms added latency. | Single ConfigMap edit (`kubectl edit cm coredns -n kube-system`). No secondary pods or custom controllers needed. | Syntax errors in the Corefile will crash CoreDNS, impacting all cluster lookups. Must validate syntax before rolling out. |
| **5. Managed EKS & Azure AKS** | **`coredns-custom` ConfigMap** (`internal.server`) | **`coredns-custom` ConfigMap** (`internal.server`) | **Both Recommended and Simplest**. Officially supported provider extension point. Survives automated EKS/AKS managed add-on upgrades. | Drop-in YAML manifest into `kube-system`. CoreDNS automatically reloads without cluster rebuild. | Requires write permissions to `kube-system` namespace. |
| **6. Google Cloud GKE Enterprise (>500 Pods)** | **GCP Cloud DNS (VPC-Scope)** Private Zone | **`kube-dns` ConfigMap `stubDomains`** | Offloads all DNS resolution to Google Cloud Anycast infrastructure. Eliminates CoreDNS OOM risk during pod scale events. | `kube-dns` ConfigMap requires only standard Kubernetes manifests without GCP IAM permissions. | Cloud DNS incurs minor per-query Google Cloud API billing. `stubDomains` adds memory pressure to in-cluster CoreDNS pods. |
| **7. Low-Latency & Strict Egress Compliance (PCI-DSS)** | **Cilium eBPF In-Kernel DNS Proxy (`toFQDNs`)** | **Cilium eBPF In-Kernel DNS Proxy (`toFQDNs`)** | **Both Recommended and Simplest (if Cilium CNI active)**. In-kernel socket shortcutting (<0.15ms latency). Dynamic IP tracking for ephemeral SaaS IPs (Stripe, Okta). | Declarative `CiliumNetworkPolicy` resource. Zero CoreDNS forwarders or Corefile alterations. | Requires Linux kernel 5.4+ and Cilium CNI. Not available on standard OpenShift OVN-Kubernetes without Cilium CNI replacement. |
| **8. Sidecarless Zero-Trust Mesh (OpenShift 4.20+)** | **Istio Ambient `ztunnel` DNS Capture + `ServiceEntry`** | **Istio Ambient `ztunnel` DNS Capture + `ServiceEntry`** | **Both Recommended and Simplest (if Ambient active)**. Captures DNS at node layer, synthesizes non-routable VIP (`240.240.0.0/16`), wraps traffic in HBONE mTLS (port 15008). | Zero OpenShift DNS Operator interactions, zero secondary resolvers, 100% transparent to applications. | Requires Istio 1.22+ or Red Hat OpenShift Service Mesh 3.x with Ambient mode enabled. |

---

### 6.3 Architectural Synthesis & Conclusions

1. **The Layer Boundary Invariance**: Layer 7 reverse proxies (Traefik, Envoy, HAProxy) cannot intercept traffic until Layer 3/4 socket handshakes succeed. Every custom FQDN architecture must provide an explicit L3/L4 name resolution mechanism before L7 policies can execute.
2. **OpenShift Immutability Rule**: In OpenShift 4.14–4.20+, the default CoreDNS Corefile is strictly immutable. Platform teams must choose between **Operator-compliant Zone Forwarding (Pattern A)**, **Split-Horizon Gateway Ingress (Approach B)**, or **Node/Kernel-Level Mesh Capture (Cilium / Istio Ambient)**.
3. **The Simplest Operational Rule**:
   - On **OpenShift on AWS (ROSA)**: Use **Approach B** (Split-Horizon Ingress via Traefik Service).
   - On **Vanilla K8s / EKS / AKS**: Use **CoreDNS native plugin / `coredns-custom`**.
   - On **Zero-Trust Mesh Fabrics**: Use **Mesh-Native Capture (`toFQDNs` / `ServiceEntry`)**.

---

## 7. References & Authoritative Sources of Truth

- **Red Hat OpenShift DNS Operator Documentation**: [https://docs.openshift.com/container-platform/latest/networking/dns-operator.html](https://docs.openshift.com/container-platform/latest/networking/dns-operator.html)  
  *Official OpenShift architecture reference for `dns.operator.openshift.io`, `spec.servers`, and zone forwarding behavior.*
- **CoreDNS Official Documentation: Rewrite Plugin**: [https://coredns.io/plugins/rewrite/](https://coredns.io/plugins/rewrite/)  
  *Upstream syntax, response code rewriting rules, and regular expression matching guidelines.*
- **Amazon EKS User Guide: Customizing CoreDNS**: [https://docs.aws.amazon.com/eks/latest/userguide/coredns-custom.html](https://docs.aws.amazon.com/eks/latest/userguide/coredns-custom.html)  
  *AWS documentation detailing the persistent `coredns-custom` ConfigMap integration across cluster upgrades.*
- **Microsoft Azure AKS Documentation: Customize CoreDNS**: [https://learn.microsoft.com/en-us/azure/aks/coredns-custom](https://learn.microsoft.com/en-us/azure/aks/coredns-custom)  
  *Official guide for setting up stub domains and custom server blocks in Azure Kubernetes Service.*
- **Google Cloud GKE Documentation: Configuring Kube-DNS / Cloud DNS**: [https://cloud.google.com/kubernetes-engine/docs/how-to/kube-dns](https://cloud.google.com/kubernetes-engine/docs/how-to/kube-dns)  
  *Upstream instructions for `kube-dns` ConfigMap `stubDomains` and VPC-native Cloud DNS routing.*
- **Red Hat OpenShift Route Configuration Documentation**: [https://docs.openshift.com/container-platform/latest/networking/routes/route-configuration.html](https://docs.openshift.com/container-platform/latest/networking/routes/route-configuration.html)  
  *Authoritative Red Hat documentation explaining arbitrary custom domain (`spec.host`) configuration without `.apps.<cluster-name>`.*
- **Kubernetes Documentation: Adding Entries to Pod /etc/hosts with HostAliases**: [https://kubernetes.io/docs/concepts/services-networking/add-entries-to-pod-etc-hosts-with-host-aliases/](https://kubernetes.io/docs/concepts/services-networking/add-entries-to-pod-etc-hosts-with-host-aliases/)  
  *Upstream reference on injecting static IP to hostname mappings at pod runtime bypassing CoreDNS.*
- **Linux man-pages: nsswitch.conf(5) & getaddrinfo(3)**: [https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html](https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html)  
  *POSIX/Linux specification detailing resolver precedence (files before dns) and L3/L4 TCP socket setup.*
- **Traefik Proxy IngressRoute Documentation**: [https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/)  
  *Official Traefik v3 documentation for IngressRoute CRD, entryPoints, and rule matching.*
- **Cilium Security Policy: DNS-Based (`toFQDNs`) Rules**: [https://docs.cilium.io/en/stable/security/policy/language/#dns-based](https://docs.cilium.io/en/stable/security/policy/language/#dns-based)  
  *Architecture guide for in-kernel DNS proxy inspection, pattern matching, and dynamic IP set synchronization.*
- **Istio Traffic Management: DNS Proxying Architecture**: [https://istio.io/latest/docs/ops/configuration/traffic-management/dns-proxy/](https://istio.io/latest/docs/ops/configuration/traffic-management/dns-proxy/)  
  *Official reference on `ISTIO_META_DNS_CAPTURE`, sidecarless node-level resolution, and `ServiceEntry` virtual VIP mapping.*
- **Companion Architecture Repository**: [https://github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws](https://github.com/nubenetes/traefik-fqdn-management-poc-openshift-aws)  
  *Production-grade reference implementation demonstrating Traefik v3 and Gateway API on Red Hat OpenShift (ROSA) on AWS with zero CoreDNS modifications, split-horizon ingress, and sidecarless mTLS.*

### 🎬 Video Masterclasses & Architectural Sessions (YouTube @nubenetes)

- 🎙️ [**Unified FQDN Routing with Traefik alternatives** (8:14)](https://www.youtube.com/watch?v=xuDtcUZYeHU)  
  *In-kernel Cilium eBPF vs. Istio Ambient mode for Unified FQDN routing without sidecars, OpenShift CoreDNS immutability, and L4 vs. L7 mechanics.*
- 🎙️ [**Gateway API y FQDNs** (8:44)](https://www.youtube.com/watch?v=vay32AcPJ9Q)  
  *Kubernetes Gateway API v1.1 GA, dual-plane FQDN resolution, and overcoming environment drift across multi-cloud distros.*
- 🎯 [**FQDN unificado en OpenShift para north-south y east-west con Traefik y Gateway API** (9:25)](https://www.youtube.com/watch?v=zUq_CYC7vM8)  
  *Solving OpenShift 4.14–4.20+ CoreDNS immutability with Traefik Proxy v3 and Gateway API: Pattern A vs. Pattern B.*
- 🚀 [**OpenShift con FQDN en north-south y east-west: Traefik vs Gateway API** (9:06)](https://www.youtube.com/watch?v=kIEqhHRf-Ks)  
  *Architectural walkthrough on ROSA: Traefik IngressRoute CRDs vs. Gateway API HTTPRoute, AWS NLB with PROXY Protocol v2, and strict mTLS.*

---

⬅️ Previous: [Architecture Deep Dive](ARCHITECTURE.md) | 🏠 [Home](../README.md) | ➡️ Next: [Gateway API without Traefik](GATEWAY_API_WITHOUT_TRAEFIK.md)
