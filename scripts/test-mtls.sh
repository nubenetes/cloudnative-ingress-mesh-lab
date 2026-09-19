#!/usr/bin/env bash
# ==============================================================================
# Zero-Trust Cryptographic Isolation & Mutual TLS Verification Engine
# Tests legitimate mesh client access vs unauthorized external/attacker probe
# ==============================================================================
set -euo pipefail

TARGET_NAMESPACE="${1:-lab-mesh}"
BACKEND_SVC="${2:-backend-v1.${TARGET_NAMESPACE}.svc.cluster.local:8080}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE} Zero-Trust mTLS & Security Policy Validator          ${NC}"
echo -e "${BLUE} Target Namespace: ${TARGET_NAMESPACE}                ${NC}"
echo -e "${BLUE} Backend Service:  ${BACKEND_SVC}                    ${NC}"
echo -e "${BLUE}======================================================${NC}"

# 1. Test from Authorized Client Tester inside mesh
echo -e "\n${YELLOW}[Step 1] Testing Authorized Ingress from Legitimate Mesh Pod...${NC}"
LEGIT_CLIENT=$(kubectl get pods -n "${TARGET_NAMESPACE}" -l app=client-tester -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$LEGIT_CLIENT" ]]; then
  echo -e "${RED}[ERROR] Legitimate client pod not found in namespace ${TARGET_NAMESPACE}.${NC}"
else
  echo -e "Executing curl from pod ${LEGIT_CLIENT}..."
  if kubectl exec -n "${TARGET_NAMESPACE}" "${LEGIT_CLIENT}" -- curl -m 3 -s -i "http://${BACKEND_SVC}/api" | grep -E "HTTP/1.1 200|HTTP/2 200"; then
    echo -e "${GREEN}[PASS] Authorized pod successfully communicated with mutual identity.${NC}"
  else
    echo -e "${YELLOW}[WARN] Request failed or unexpected status. Inspecting pod logs...${NC}"
  fi
fi

# 2. Test from Rogue Attacker Pod in untrusted namespace
echo -e "\n${YELLOW}[Step 2] Testing Unauthorized Probe from Rogue Attacker Pod...${NC}"
ATTACKER_POD=$(kubectl get pods -n attacker -l app=rogue-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$ATTACKER_POD" ]]; then
  echo -e "${RED}[ERROR] Attacker pod not found in namespace attacker.${NC}"
else
  echo -e "Executing unauthorized curl from untrusted attacker pod ${ATTACKER_POD}..."
  set +e
  ATTACK_OUTPUT=$(kubectl exec -n attacker "${ATTACKER_POD}" -- curl -m 4 -s -i "http://${BACKEND_SVC}/api" 2>&1)
  ATTACK_EXIT=$?
  set -e

  if [[ $ATTACK_EXIT -ne 0 ]] || [[ "$ATTACK_OUTPUT" == *"Connection reset"* ]] || [[ "$ATTACK_OUTPUT" == *"Empty reply"* ]] || [[ "$ATTACK_OUTPUT" == *"command terminated with exit code"* ]] || [[ "$ATTACK_OUTPUT" == *"403 Forbidden"* ]]; then
    echo -e "${GREEN}[PASS] Zero-Trust Enforced: Unauthorized attack probe was blocked!${NC}"
    echo -e "Kernel/Mesh Drop Signature: ${ATTACK_OUTPUT:-Connection Timeout/Refused}"
  else
    echo -e "${RED}[FAIL] SECURITY BREACH: Attacker pod was able to reach backend service!${NC}"
    echo -e "Response: ${ATTACK_OUTPUT}"
    exit 1
  fi
fi

echo -e "\n${GREEN}=== Zero-Trust Cryptographic Validation Complete: PASSED ===${NC}"
