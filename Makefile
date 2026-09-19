# ==============================================================================
# Cloud-Native Ingress & Service Mesh Laboratory (2026 Edition)
# Global Automation Orchestrator for Kubernetes Gateway API, Cilium, Istio Ambient, and Traefik v3
# ==============================================================================

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Cluster Configurations
KIND_CLUSTER_CILIUM  ?= lab-cilium
KIND_CLUSTER_ISTIO   ?= lab-istio
KIND_CLUSTER_TRAEFIK ?= lab-traefik

GATEWAY_API_VERSION  ?= v1.1.0
CILIUM_VERSION       ?= 1.16.0
ISTIO_VERSION        ?= 1.23.0
TRAEFIK_VERSION      ?= 31.0.0

COLOR_RESET   := \033[0m
COLOR_INFO    := \033[36m
COLOR_SUCCESS := \033[32m
COLOR_WARNING := \033[33m
COLOR_DANGER  := \033[31m

.PHONY: help
help: ## Display the comprehensive catalog of automation targets
	@echo -e "$(COLOR_INFO)=====================================================================$(COLOR_RESET)"
	@echo -e "$(COLOR_INFO)  Cloud-Native Ingress & Service Mesh Laboratory - Global Orchestrator$(COLOR_RESET)"
	@echo -e "$(COLOR_INFO)=====================================================================$(COLOR_RESET)"
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Prerequisites & Gateway API CRDs

.PHONY: check-deps
check-deps: ## Verify that host dependencies (docker, kind, kubectl, helm, jq, curl) are installed
	@echo -e "$(COLOR_INFO)[*] Verifying host dependencies...$(COLOR_RESET)"
	@command -v docker >/dev/null 2>&1 || (echo -e "$(COLOR_DANGER)[!] Docker is required$(COLOR_RESET)" && exit 1)
	@command -v kind >/dev/null 2>&1 || (echo -e "$(COLOR_WARNING)[!] Kind not found in PATH; ensure Kind or OpenShift is accessible$(COLOR_RESET)")
	@command -v kubectl >/dev/null 2>&1 || (echo -e "$(COLOR_DANGER)[!] kubectl is required$(COLOR_RESET)" && exit 1)
	@command -v helm >/dev/null 2>&1 || (echo -e "$(COLOR_DANGER)[!] helm is required$(COLOR_RESET)" && exit 1)
	@command -v curl >/dev/null 2>&1 || (echo -e "$(COLOR_DANGER)[!] curl is required$(COLOR_RESET)" && exit 1)
	@command -v jq >/dev/null 2>&1 || (echo -e "$(COLOR_WARNING)[!] jq recommended for JSON parsing$(COLOR_RESET)")
	@echo -e "$(COLOR_SUCCESS)[✓] Core prerequisites verified.$(COLOR_RESET)"

.PHONY: install-gateway-api
install-gateway-api: ## Install official Kubernetes Gateway API standard and experimental CRDs
	@echo -e "$(COLOR_INFO)[*] Installing Gateway API CRDs ($(GATEWAY_API_VERSION))...$(COLOR_RESET)"
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/experimental-install.yaml
	@echo -e "$(COLOR_SUCCESS)[✓] Gateway API v1 CRDs installed.$(COLOR_RESET)"

##@ Lab 1: Cilium eBPF Gateway & Service Mesh

.PHONY: kind-create-cilium
kind-create-cilium: ## Provision Kind cluster for Cilium with no default CNI and BPF filesystem mounted
	@echo -e "$(COLOR_INFO)[*] Provisioning Kind cluster '$(KIND_CLUSTER_CILIUM)' for Cilium...$(COLOR_RESET)"
	kind create cluster --name $(KIND_CLUSTER_CILIUM) --config deploys/cilium/kind-config.yaml
	@echo -e "$(COLOR_SUCCESS)[✓] Kind cluster $(KIND_CLUSTER_CILIUM) created.$(COLOR_RESET)"

.PHONY: setup-cilium
setup-cilium: check-deps install-gateway-api ## Deploy Cilium with eBPF Gateway API, sockops, and Hubble
	@echo -e "$(COLOR_INFO)[*] Deploying Cilium $(CILIUM_VERSION) via Helm...$(COLOR_RESET)"
	helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
	helm repo update cilium
	helm upgrade --install cilium cilium/cilium \
		--version $(CILIUM_VERSION) \
		--namespace kube-system \
		-f deploys/cilium/helm-values.yaml
	@echo -e "$(COLOR_INFO)[*] Waiting for Cilium DaemonSet to be ready...$(COLOR_RESET)"
	kubectl -n kube-system rollout status ds/cilium --timeout=180s
	@echo -e "$(COLOR_INFO)[*] Deploying Workloads & Gateway API manifests for Cilium...$(COLOR_RESET)"
	kubectl create namespace lab-cilium 2>/dev/null || true
	kubectl create namespace attacker 2>/dev/null || true
	kubectl apply -f deploys/common/backend-v1.yaml -n lab-cilium
	kubectl apply -f deploys/common/backend-v2.yaml -n lab-cilium
	kubectl apply -f deploys/common/client-tester.yaml
	kubectl apply -f deploys/cilium/gateway.yaml
	kubectl apply -f deploys/cilium/httproute-canary.yaml
	kubectl apply -f deploys/cilium/cilium-clusterwide-policy.yaml
	@echo -e "$(COLOR_SUCCESS)[✓] Cilium eBPF Gateway and Mesh deployed.$(COLOR_RESET)"

.PHONY: test-traffic-cilium
test-traffic-cilium: ## Send live traffic through Cilium Gateway API and inspect headers/tracing
	@echo -e "$(COLOR_INFO)[*] Testing live traffic through Cilium Gateway...$(COLOR_RESET)"
	@GW_IP=$$(kubectl get gateway cilium-gw -n lab-cilium -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "127.0.0.1"); \
	echo "Probing http://$$GW_IP/api..."; \
	for i in {1..5}; do \
		curl -s -i "http://$$GW_IP/api" | head -n 10; \
		echo "---"; \
		sleep 1; \
	done

.PHONY: test-canary-cilium
test-canary-cilium: ## Execute 100-request statistical verification of Cilium 90/10 Canary split
	@GW_IP=$$(kubectl get gateway cilium-gw -n lab-cilium -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "127.0.0.1"); \
	./scripts/test-canary.sh "http://$$GW_IP/api" 100

.PHONY: test-mtls-cilium
test-mtls-cilium: ## Validate zero-trust eBPF policy isolation against unauthorized attacker pod
	./scripts/test-mtls.sh "lab-cilium" "backend-v1.lab-cilium.svc.cluster.local:8080"

.PHONY: clean-cilium
clean-cilium: ## Destroy Cilium Kind cluster and reset environment
	@echo -e "$(COLOR_WARNING)[!] Deleting Cilium cluster...$(COLOR_RESET)"
	kind delete cluster --name $(KIND_CLUSTER_CILIUM) 2>/dev/null || true
	@echo -e "$(COLOR_SUCCESS)[✓] Cilium environment cleaned.$(COLOR_RESET)"

##@ Lab 2: Sidecarless Istio Ambient Mode

.PHONY: kind-create-istio
kind-create-istio: ## Provision Kind cluster for Istio Ambient with port forwarding
	@echo -e "$(COLOR_INFO)[*] Provisioning Kind cluster '$(KIND_CLUSTER_ISTIO)' for Istio Ambient...$(COLOR_RESET)"
	kind create cluster --name $(KIND_CLUSTER_ISTIO) --config deploys/istio/kind-config.yaml
	@echo -e "$(COLOR_SUCCESS)[✓] Kind cluster $(KIND_CLUSTER_ISTIO) created.$(COLOR_RESET)"

.PHONY: setup-istio
setup-istio: check-deps install-gateway-api ## Deploy Istio Ambient (ztunnel + istiod) and Waypoint proxy
	@echo -e "$(COLOR_INFO)[*] Deploying Istio Ambient via Helm...$(COLOR_RESET)"
	helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
	helm repo update istio
	helm upgrade --install istio-base istio/base -n istio-system --create-namespace
	helm upgrade --install istiod istio/istiod -n istio-system \
		--set profile=ambient \
		--set pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true \
		--wait
	helm upgrade --install ztunnel istio/ztunnel -n istio-system --wait
	helm upgrade --install istio-cni istio/cni -n istio-system --set profile=ambient --wait
	@echo -e "$(COLOR_INFO)[*] Enrolling namespace in Ambient data plane...$(COLOR_RESET)"
	kubectl create namespace lab-istio 2>/dev/null || true
	kubectl create namespace attacker 2>/dev/null || true
	kubectl label namespace lab-istio istio.io/dataplane-mode=ambient --overwrite
	@echo -e "$(COLOR_INFO)[*] Deploying microservices and Waypoint Gateway...$(COLOR_RESET)"
	kubectl apply -f deploys/common/backend-v1.yaml -n lab-istio
	kubectl apply -f deploys/common/backend-v2.yaml -n lab-istio
	kubectl apply -f deploys/common/frontend.yaml -n lab-istio
	kubectl apply -f deploys/common/client-tester.yaml
	kubectl apply -f deploys/istio/waypoint-gateway.yaml
	kubectl apply -f deploys/istio/ingress-gateway.yaml
	kubectl apply -f deploys/istio/httproute-canary.yaml
	kubectl apply -f deploys/istio/authorization-policy.yaml
	@echo -e "$(COLOR_SUCCESS)[✓] Istio Ambient mesh and Waypoint proxy deployed.$(COLOR_RESET)"

.PHONY: test-traffic-istio
test-traffic-istio: ## Test live traffic through Istio Ambient Ingress & Waypoint
	@echo -e "$(COLOR_INFO)[*] Probing Istio Ingress Gateway on http://127.0.0.1/api...$(COLOR_RESET)"
	@for i in {1..5}; do \
		curl -s -i "http://127.0.0.1/api" | head -n 10; \
		echo "---"; \
		sleep 1; \
	done

.PHONY: test-canary-istio
test-canary-istio: ## Execute 100-request statistical verification of Istio Ambient 90/10 Canary split
	./scripts/test-canary.sh "http://127.0.0.1/api" 100

.PHONY: test-mtls-istio
test-mtls-istio: ## Verify HBONE mTLS rejection against unauthenticated attacker pod
	./scripts/test-mtls.sh "lab-istio" "backend-v1.lab-istio.svc.cluster.local:8080"

.PHONY: clean-istio
clean-istio: ## Destroy Istio Kind cluster
	@echo -e "$(COLOR_WARNING)[!] Deleting Istio Ambient cluster...$(COLOR_RESET)"
	kind delete cluster --name $(KIND_CLUSTER_ISTIO) 2>/dev/null || true
	@echo -e "$(COLOR_SUCCESS)[✓] Istio Ambient environment cleaned.$(COLOR_RESET)"

##@ Lab 3: Traefik v3 Edge Gateway

.PHONY: kind-create-traefik
kind-create-traefik: ## Provision Kind cluster for Traefik v3 Edge router
	@echo -e "$(COLOR_INFO)[*] Provisioning Kind cluster '$(KIND_CLUSTER_TRAEFIK)' for Traefik...$(COLOR_RESET)"
	kind create cluster --name $(KIND_CLUSTER_TRAEFIK) --config deploys/traefik/kind-config.yaml
	@echo -e "$(COLOR_SUCCESS)[✓] Kind cluster $(KIND_CLUSTER_TRAEFIK) created.$(COLOR_RESET)"

.PHONY: setup-traefik
setup-traefik: check-deps install-gateway-api ## Deploy Traefik v3 with native Gateway API provider & Middlewares
	@echo -e "$(COLOR_INFO)[*] Deploying Traefik v3 via Helm...$(COLOR_RESET)"
	helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
	helm repo update traefik
	helm upgrade --install traefik traefik/traefik \
		--version $(TRAEFIK_VERSION) \
		--namespace traefik-system \
		--create-namespace \
		-f deploys/traefik/helm-values.yaml \
		--wait
	@echo -e "$(COLOR_INFO)[*] Deploying Workloads & Gateway API Route Manifests...$(COLOR_RESET)"
	kubectl create namespace lab-traefik 2>/dev/null || true
	kubectl apply -f deploys/common/backend-v1.yaml -n lab-traefik
	kubectl apply -f deploys/common/backend-v2.yaml -n lab-traefik
	kubectl apply -f deploys/traefik/gateway.yaml
	kubectl apply -f deploys/traefik/middlewares.yaml
	kubectl apply -f deploys/traefik/httproute-canary.yaml
	@echo -e "$(COLOR_SUCCESS)[✓] Traefik v3 Gateway API Router and Middlewares deployed.$(COLOR_RESET)"

.PHONY: test-traffic-traefik
test-traffic-traefik: ## Test live traffic and inspect Traefik security response headers
	@echo -e "$(COLOR_INFO)[*] Probing Traefik v3 Edge Gateway on http://127.0.0.1/api...$(COLOR_RESET)"
	@for i in {1..5}; do \
		curl -s -i "http://127.0.0.1/api" | grep -E "HTTP|X-Engineered-By|X-Frame-Options|version"; \
		echo "---"; \
		sleep 1; \
	done

.PHONY: test-canary-traefik
test-canary-traefik: ## Execute 100-request statistical verification of Traefik 90/10 Canary split
	./scripts/test-canary.sh "http://127.0.0.1/api" 100

.PHONY: clean-traefik
clean-traefik: ## Destroy Traefik Kind cluster
	@echo -e "$(COLOR_WARNING)[!] Deleting Traefik cluster...$(COLOR_RESET)"
	kind delete cluster --name $(KIND_CLUSTER_TRAEFIK) 2>/dev/null || true
	@echo -e "$(COLOR_SUCCESS)[✓] Traefik environment cleaned.$(COLOR_RESET)"

##@ Global Cleanup & Reset

.PHONY: clean-all
clean-all: clean-cilium clean-istio clean-traefik ## Destroy all laboratory Kind clusters and temporary resources
	@echo -e "$(COLOR_SUCCESS)[✓] All laboratory clusters have been destroyed.$(COLOR_RESET)"
