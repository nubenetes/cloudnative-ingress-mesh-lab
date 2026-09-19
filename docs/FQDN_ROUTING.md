[🏠 Home / README](../README.md) | [Architecture](ARCHITECTURE.md) | **FQDN Routing** | [Lab 1: Cilium](LAB_CILIUM.md) | [Lab 2: Istio Ambient](LAB_ISTIO_AMBIENT.md) | [Lab 3: Traefik Edge](LAB_TRAEFIK_EDGE.md)

---

# FQDN-Driven Routing: North-South & East-West Architecture Across Kubernetes Distributions & Red Hat OpenShift 4.20+

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
- [6. References & Authoritative Sources of Truth](#6-references--authoritative-sources-of-truth)

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

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        NORTH-SOUTH TRANSIT (External -> Cluster)                       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ [External / Corporate Client]                                                          │
│        │                                                                               │
│        │ 1. Resolves `backend.internal.corp` via Corporate/Public DNS (Infoblox/Route53)│
│        │    -> Returns OpenShift Ingress VIP / Load Balancer IP                        │
│        ▼                                                                               │
│ [OpenShift Ingress VIP / Traefik Gateway (L7 Reverse Proxy)]                           │
│        │ 2. Receives TCP SYN -> Completes TLS Handshake -> Inspects HTTP Host header   │
│        │ 3. Matches `Host(`backend.internal.corp`)` -> Routes to backend pods          │
│                                                                                        │
│ 🎯 CoreDNS Status: 0% CoreDNS interaction! OpenShift CoreDNS is NEVER queried.         │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        EAST-WEST TRANSIT (Pod A -> Pod B inside Cluster)               │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ [Client Pod A in OpenShift]                                                            │
│        │                                                                               │
│        │ 1. Executes: `curl http://backend.internal.corp/api`                          │
│        │ 2. Linux OS resolver (`glibc`/`musl` `getaddrinfo`) consults `/etc/resolv.conf│
│        │    -> Queries OpenShift cluster DNS (`172.30.0.10:53`)                        │
│        ▼                                                                               │
│ [OpenShift DNS Operator / CoreDNS]                                                     │
│        │                                                                               │
│        ├── IF `backend.internal.corp` is UNKNOWN to CoreDNS:                           │
│        │   └── CoreDNS returns `NXDOMAIN` (Name Error)                                │
│        │       └── Pod A OS aborts: `curl: (6) Could not resolve host`                │
│        │           🚨 Traefik is NEVER reached! L7 Middlewares NEVER execute!          │
│        │                                                                               │
│        └── IF DNS resolves to Traefik ClusterIP (via Forwarder, hostAliases, or Corp): │
│            └── Pod A opens TCP connection to Traefik ClusterIP                         │
│                └── Traefik matches `Host(`backend.internal.corp`)` & applies Middlewares│
└────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Why Traefik Middlewares Cannot Bypass DNS Resolution (The OSI Model Boundary)
1. **Layer 3/4 Socket Precedence**: Traefik is an application-layer (Layer 7) reverse proxy. An HTTP request or middleware pipeline cannot physically execute until a TCP three-way handshake (SYN, SYN-ACK, ACK) completes.
2. **Client-Side Resolution**: To send a TCP SYN packet to Traefik, the Linux kernel network stack in Pod A requires a destination IPv4/IPv6 address. When the application calls `http://backend.internal.corp`, the OS runtime invokes `getaddrinfo(3)`, which evaluates `/etc/nsswitch.conf` (`hosts: files dns`).
3. **Traefik Isolation**: Traefik cannot intercept the packet until traffic actually arrives at its listening socket. Without DNS resolution or `/etc/hosts` mapping, the kernel drops or aborts the request before any packet leaves the node.

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

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│  APPROACH A: Transparent In-Cluster DNS Interception (cloudnative-ingress-mesh-lab)   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│  Client Pod Syntax: `curl http://backend.internal.corp/api`                            │
│  • Client is completely agnostic to gateway addresses; calls business FQDN directly.   │
│  • L3/L4 Resolution: Handled by OpenShift DNS Operator zone forwarding (`spec.servers`)│
│    pointing to an unprivileged in-cluster CoreDNS resolver (`infra-dns`), or kernel    │
│    eBPF socket interception (Cilium), or node-level capture (Istio Ambient ztunnel).   │
│  • Target Environment: Multi-distribution (OpenShift, EKS, AKS, GKE, Vanilla/BareMetal)│
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│  APPROACH B: Split-Horizon Ingress via Traefik Service (traefik-fqdn-management-poc)   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│  Client Pod Syntax: `curl -H "Host: service-b.apps.cluster.local"                      │
│                           https://traefik.traefik-system.svc.cluster.local:8443`       │
│  • Client addresses the gateway's native Kubernetes Service FQDN (`*.svc.cluster.local`)│
│  • L3/L4 Resolution: Resolved 100% natively by OpenShift CoreDNS out-of-the-box!       │
│  • L7 Policy: Traefik inspects the HTTP `Host` header, validates client mTLS certs     │
│    (`RequireAndVerifyClientCert`), checks OVN-Kubernetes CIDR allowlists, and routes.  │
│  • Target Environment: Cloud-native AWS ROSA / EKS leveraging NLBs & Route 53.         │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

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

```
[ Workload Pod ]
       │
       │ 1. DNS Query: `backend.internal.corp`
       ▼
[ OpenShift DNS Operator: dns-default ]
       │
       │ 2. Evaluates `spec.servers`: matches zone `internal.corp`
       │    Forwards query to internal-dns-service.infra-dns:53
       ▼
[ Secondary CoreDNS: infra-dns ]
       │
       │ 3. Executes `rewrite name regex ... traefik.traefik-system.svc.cluster.local`
       │    Returns Traefik ClusterIP!
       ▼
[ Workload Pod communicates directly with Traefik Edge Router ]
```

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

---

### 2.4 Vanilla Kubernetes, Kind & SUSE RKE2: CoreDNS `rewrite` Plugin

In vanilla Kubernetes clusters (including Kind, K3s, kubeadm, and RKE2), CoreDNS is directly configurable via the `Corefile` in the `kube-system/coredns` ConfigMap:

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

---

### 2.5 Amazon EKS: `coredns-custom` ConfigMap

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

### 2.6 Microsoft Azure AKS: `coredns-custom` ConfigMap

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

### 2.7 Google Cloud GKE: Cloud DNS & Kube-DNS Stub Domains

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

---

## 3. Traefik v3 Implementation (without Traefik Mesh)

Once DNS is routed to Traefik, Traefik functions as an **East-West Internal Gateway** using native `IngressRoute` and `Middleware` definitions without needing sidecar injection.

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

---

## 4. Mesh-Native Transparent DNS (Zero CoreDNS Alterations)

The most elegant architectural breakthrough of modern meshes like **Cilium eBPF** and **Istio Ambient** is that **they completely eliminate the need to modify cluster DNS operators or CoreDNS!**

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│              eBPF / Ambient DNS Redirection (No Corefile Mod Required)          │
├─────────────────────────────────────────────────────────────────────────────────┤
│ 1. Application pod calls getaddrinfo("backend.internal.corp")                   │
│ 2. Packet intercepted directly in Linux Kernel (cgroup2 / ztunnel socket)       │
│ 3. Mesh agent resolves FQDN from internal ServiceEntry or eBPF Map              │
│ 4. Response returned instantly; CoreDNS pods are completely bypassed!           │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Cilium eBPF: In-Kernel DNS Proxy & `toFQDNs` Egress Policies

Cilium attaches eBPF programs to the pod's cgroup socket layer. When a container sends a DNS request, Cilium intercepts it transparently at the kernel layer, inspects FQDN rules, and builds in-kernel ipsets:

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

---

### 4.2 Istio Ambient: Node-Level ztunnel DNS Capture & `ServiceEntry`

In Istio Ambient, DNS proxying is built into the node-level **`ztunnel`** (`ISTIO_META_DNS_CAPTURE=true`). When an internal pod requests `backend.internal.corp`:
1. `ztunnel` captures the query on the node and returns an internally synthesized virtual IP (`240.240.0.100`) from an **Istio `ServiceEntry`**.
2. When the app sends TCP traffic to that VIP, `ztunnel` encapsulates the packet in HBONE (port 15008) with mutual TLS.
3. Traffic is forwarded to the namespace **`waypoint`** proxy, which applies L7 `HTTPRoute` rules matching the FQDN hostname.
4. **Works on Red Hat OpenShift 4.20+ out-of-the-box without touching the OpenShift DNS Operator!**

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

## 6. References & Authoritative Sources of Truth

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

---

⬅️ Previous: [Architecture Deep Dive](ARCHITECTURE.md) | 🏠 [Home](../README.md) | ➡️ Next: [Lab 1: Cilium eBPF](LAB_CILIUM.md)
