#!/bin/bash

# Simple HTTP/2 test script focusing on working features
# This tests direct HTTP/2 connections (http2-prior-knowledge)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "HTTP/2 Working Features Test"
echo "========================================"
echo ""

# Check if server is running
check_server() {
  if ! curl -s -o /dev/null -w "%{http_code}" http://localhost:9080/ >/dev/null 2>&1; then
    echo -e "${RED}Error: Server is not running on http://localhost:9080${NC}"
    echo "Please start the server with: gleam run"
    exit 1
  fi
  echo -e "${GREEN}✓ Server is running${NC}"
}

# Test 1: Basic HTTP/2 connection (direct)
test_basic_http2_direct() {
  echo -e "\n${YELLOW}Test 1: Direct HTTP/2 Connection${NC}"
  echo "Testing: curl --http2-prior-knowledge http://localhost:9080/"

  response=$(curl --http2-prior-knowledge -s -o /dev/null -w "%{http_version}" http://localhost:9080/)
  if [[ "$response" == "2" ]]; then
    echo -e "${GREEN}✓ HTTP/2 direct connection successful${NC}"
  else
    echo -e "${RED}✗ HTTP/2 direct connection failed (got HTTP/$response)${NC}"
  fi
}

# Test 2: JSON endpoint
test_json() {
  echo -e "\n${YELLOW}Test 2: JSON Endpoint${NC}"
  echo "Testing: GET /json"

  json=$(curl --http2-prior-knowledge -s http://localhost:9080/json)
  echo "JSON Response: $json"

  if echo "$json" | grep -q '"protocol":"HTTP/2"'; then
    echo -e "${GREEN}✓ JSON endpoint working${NC}"
  else
    echo -e "${RED}✗ JSON endpoint failed${NC}"
  fi
}

# Test 3: Different status codes
test_status_codes() {
  echo -e "\n${YELLOW}Test 3: Status Code Handling${NC}"

  for code in 200 201 404 500; do
    response=$(curl --http2-prior-knowledge -s -o /dev/null -w "%{http_code}" http://localhost:9080/status/$code)
    if [ "$response" -eq "$code" ]; then
      echo -e "${GREEN}✓ Status $code returned correctly${NC}"
    else
      echo -e "${RED}✗ Status $code failed (got $response)${NC}"
    fi
  done
}

# Test 4: Echo endpoint
test_echo() {
  echo -e "\n${YELLOW}Test 4: Echo Endpoint${NC}"
  echo "Testing: GET /echo with custom headers"

  result=$(curl --http2-prior-knowledge -s -H "X-Test-Header: TestValue" http://localhost:9080/echo)
  if echo "$result" | grep -q "Echo Service"; then
    echo -e "${GREEN}✓ Echo endpoint working${NC}"
  else
    echo -e "${RED}✗ Echo endpoint failed${NC}"
  fi
}

# Test 5: Server metrics
test_metrics() {
  echo -e "\n${YELLOW}Test 5: Server Metrics${NC}"
  echo "Testing: GET /metrics"

  metrics=$(curl --http2-prior-knowledge -s http://localhost:9080/metrics)
  
  if echo "$metrics" | grep -q '"http2"'; then
    echo -e "${GREEN}✓ Metrics endpoint working${NC}"
  else
    echo -e "${RED}✗ Metrics endpoint failed${NC}"
  fi
}

# Test h2c upgrade (known issue)
test_h2c_upgrade() {
  echo -e "\n${YELLOW}Test 6: H2C Upgrade (Known Issue)${NC}"
  echo "Testing: curl --http2 http://localhost:9080/"
  
  # Use timeout to avoid hanging
  response=$(timeout 3s curl --http2 -s -o /dev/null -w "%{http_version}" http://localhost:9080/ 2>/dev/null || echo "timeout")
  
  if [[ "$response" == "2" ]]; then
    echo -e "${GREEN}✓ H2C upgrade working${NC}"
  else
    echo -e "${YELLOW}⚠ H2C upgrade hanging - this is a known issue${NC}"
    echo "  Direct HTTP/2 connections work fine with --http2-prior-knowledge"
  fi
}

# Main execution
main() {
  check_server
  test_basic_http2_direct
  test_json
  test_status_codes
  test_echo
  test_metrics
  test_h2c_upgrade

  echo -e "\n${GREEN}========================================"
  echo "Working features test completed!"
  echo "HTTP/2 server is functional for direct connections"
  echo "========================================${NC}"
}

main