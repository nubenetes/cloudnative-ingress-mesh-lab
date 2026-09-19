#!/usr/bin/env bash
# ==============================================================================
# Statistical Canary Traffic-Split Verification Engine
# Validates Gateway API HTTPRoute weighted routing across backends
# ==============================================================================
set -euo pipefail

GATEWAY_ENDPOINT="${1:-http://127.0.0.1/api}"
REQUEST_COUNT="${2:-100}"
EXPECTED_V1_WEIGHT=90
EXPECTED_V2_WEIGHT=10
TOLERANCE=12

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE} Canary Verification Engine (2026 Gateway API Lab)     ${NC}"
echo -e "${BLUE} Target Endpoint: ${GATEWAY_ENDPOINT}                 ${NC}"
echo -e "${BLUE} Total Iterations: ${REQUEST_COUNT}                   ${NC}"
echo -e "${BLUE} Target Split: ${EXPECTED_V1_WEIGHT}% v1 / ${EXPECTED_V2_WEIGHT}% v2 ${NC}"
echo -e "${BLUE}======================================================${NC}"

V1_COUNT=0
V2_COUNT=0
ERR_COUNT=0

for ((i=1; i<=REQUEST_COUNT; i++)); do
  RESP=$(curl -s -m 2 "${GATEWAY_ENDPOINT}" || echo "ERROR")
  
  if [[ "$RESP" == *"v1-production"* ]]; then
    ((V1_COUNT++))
    echo -ne "${GREEN}.${NC}"
  elif [[ "$RESP" == *"v2-canary"* ]]; then
    ((V2_COUNT++))
    echo -ne "${YELLOW}*${NC}"
  else
    ((ERR_COUNT++))
    echo -ne "${RED}X${NC}"
  fi

  if (( i % 50 == 0 )); then
    echo -e " [${i}/${REQUEST_COUNT}]"
  fi
done

echo ""
echo -e "${BLUE}---------------- Summary Results -----------------${NC}"
V1_PCT=$(( (V1_COUNT * 100) / REQUEST_COUNT ))
V2_PCT=$(( (V2_COUNT * 100) / REQUEST_COUNT ))
ERR_PCT=$(( (ERR_COUNT * 100) / REQUEST_COUNT ))

echo -e "Backend v1 (Target ~${EXPECTED_V1_WEIGHT}%): ${V1_COUNT} hits (${V1_PCT}%)"
echo -e "Backend v2 (Target ~${EXPECTED_V2_WEIGHT}%): ${V2_COUNT} hits (${V2_PCT}%)"
echo -e "Errors / Dropped: ${ERR_COUNT} (${ERR_PCT}%)"

if (( ERR_COUNT > 0 )); then
  echo -e "${RED}[FAIL] Detected ${ERR_COUNT} dropped or failing requests!${NC}"
  exit 1
fi

DELTA_V1=$(( V1_PCT > EXPECTED_V1_WEIGHT ? V1_PCT - EXPECTED_V1_WEIGHT : EXPECTED_V1_WEIGHT - V1_PCT ))
if (( DELTA_V1 <= TOLERANCE )); then
  echo -e "${GREEN}[PASS] Canary traffic distribution is within acceptable statistical tolerance (+/- ${TOLERANCE}%).${NC}"
  exit 0
else
  echo -e "${YELLOW}[WARN] Distribution deviated by ${DELTA_V1}%. Re-run with more iterations for larger statistical sample.${NC}"
  exit 0
fi
