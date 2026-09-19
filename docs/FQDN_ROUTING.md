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
- **Cilium Security Policy: DNS-Based (`toFQDNs`) Rules**: [https://docs.cilium.io/en/stable/security/policy/language/#dns-based](https://docs.cilium.io/en/stable/security/policy/language/#dns-based)  
  *Architecture guide for in-kernel DNS proxy inspection, pattern matching, and dynamic IP set synchronization.*
- **Istio Traffic Management: DNS Proxying Architecture**: [https://istio.io/latest/docs/ops/configuration/traffic-management/dns-proxy/](https://istio.io/latest/docs/ops/configuration/traffic-management/dns-proxy/)  
  *Official reference on `ISTIO_META_DNS_CAPTURE`, sidecarless node-level resolution, and `ServiceEntry` virtual VIP mapping.*

---

⬅️ Previous: [Architecture Deep Dive](ARCHITECTURE.md) | 🏠 [Home](../README.md) | ➡️ Next: [Lab 1: Cilium eBPF](LAB_CILIUM.md)
