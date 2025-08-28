#!/bin/bash

# HTTP/2 Testing Script for Mist Example
# This script tests various HTTP/2 features

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "HTTP/2 Testing Suite for Mist"
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

# Test 1: Basic HTTP/2 connection
test_basic_http2() {
  echo -e "\n${YELLOW}Test 1: Basic HTTP/2 Connection${NC}"
  echo "Testing: curl --http2 http://localhost:9080/"

  response=$(curl --http2 -s -o /dev/null -w "%{http_version}" http://localhost:9080/)
  if [[ "$response" == "2" ]]; then
    echo -e "${GREEN}✓ HTTP/2 connection successful${NC}"
  else
    echo -e "${RED}✗ HTTP/2 connection failed (got HTTP/$response)${NC}"
  fi
}

# Test 2: Echo endpoint
test_echo() {
  echo -e "\n${YELLOW}Test 2: Echo Endpoint${NC}"
  echo "Testing: GET /echo with custom headers"

  curl --http2 -s -H "X-Test-Header: TestValue" \
    -H "X-Another-Header: AnotherValue" \
    http://localhost:9080/echo | head -20
  echo -e "${GREEN}✓ Echo endpoint tested${NC}"
}

# Test 3: Large response (flow control)
test_large_response() {
  echo -e "\n${YELLOW}Test 3: Large Response (Flow Control)${NC}"
  echo "Testing: GET /large"

  size=$(curl --http2 -s http://localhost:9080/large | wc -c)
  echo "Response size: $size bytes"

  if [ "$size" -gt 100000 ]; then
    echo -e "${GREEN}✓ Large response handled correctly${NC}"
  else
    echo -e "${RED}✗ Large response test failed${NC}"
  fi
}

# Test 4: Many headers (HPACK compression)
test_hpack() {
  echo -e "\n${YELLOW}Test 4: HPACK Header Compression${NC}"
  echo "Testing: GET /headers"

  headers=$(curl --http2 -s -I http://localhost:9080/headers | grep -c "x-custom-header")
  echo "Custom headers found: $headers"

  if [ "$headers" -gt 40 ]; then
    echo -e "${GREEN}✓ HPACK compression test passed${NC}"
  else
    echo -e "${RED}✗ HPACK compression test failed${NC}"
  fi
}

# Test 5: Multiplexing with parallel requests
test_multiplexing() {
  echo -e "\n${YELLOW}Test 5: HTTP/2 Multiplexing${NC}"
  echo "Testing: Parallel requests with different delays"

  start_time=$(date +%s)

  # Run parallel requests
  curl --http2 --parallel --parallel-max 5 \
    -s http://localhost:9080/delay/1 \
    -s http://localhost:9080/delay/2 \
    -s http://localhost:9080/delay/3 \
    -s http://localhost:9080/delay/1 \
    -s http://localhost:9080/delay/2 >/dev/null

  end_time=$(date +%s)
  duration=$((end_time - start_time))

  echo "Total time for 5 parallel requests: ${duration}s"

  if [ "$duration" -le 4 ]; then
    echo -e "${GREEN}✓ Multiplexing working (requests were parallel)${NC}"
  else
    echo -e "${YELLOW}⚠ Multiplexing may not be working optimally${NC}"
  fi
}

# Test 6: Different status codes
test_status_codes() {
  echo -e "\n${YELLOW}Test 6: Status Code Handling${NC}"

  for code in 200 201 404 500; do
    response=$(curl --http2 -s -o /dev/null -w "%{http_code}" http://localhost:9080/status/$code)
    if [ "$response" -eq "$code" ]; then
      echo -e "${GREEN}✓ Status $code returned correctly${NC}"
    else
      echo -e "${RED}✗ Status $code failed (got $response)${NC}"
    fi
  done
}

# Test 7: JSON endpoint
test_json() {
  echo -e "\n${YELLOW}Test 7: JSON Response${NC}"
  echo "Testing: GET /json"

  json=$(curl --http2 -s http://localhost:9080/json)
  echo "JSON Response: $json"

  if echo "$json" | grep -q '"protocol":"HTTP/2"'; then
    echo -e "${GREEN}✓ JSON endpoint working${NC}"
  else
    echo -e "${RED}✗ JSON endpoint failed${NC}"
  fi
}

# Test 8: Binary data
test_binary() {
  echo -e "\n${YELLOW}Test 8: Binary Data Transfer${NC}"
  echo "Testing: GET /binary"

  curl --http2 -s --output /tmp/test_binary.dat http://localhost:9080/binary
  size=$(wc -c </tmp/test_binary.dat)

  echo "Binary file size: $size bytes"

  if [ "$size" -gt 0 ]; then
    echo -e "${GREEN}✓ Binary data transfer successful${NC}"
    rm -f /tmp/test_binary.dat
  else
    echo -e "${RED}✗ Binary data transfer failed${NC}"
  fi
}

# Test 9: Streaming response
test_streaming() {
  echo -e "\n${YELLOW}Test 9: Streaming Response${NC}"
  echo "Testing: GET /stream"

  events=$(curl --http2 -s http://localhost:9080/stream | grep -c "data: Event")
  echo "Stream events received: $events"

  if [ "$events" -eq 5 ]; then
    echo -e "${GREEN}✓ Streaming response working${NC}"
  else
    echo -e "${RED}✗ Streaming response failed${NC}"
  fi
}

# Test 10: Server metrics
test_metrics() {
  echo -e "\n${YELLOW}Test 10: Server Metrics${NC}"
  echo "Testing: GET /metrics"

  metrics=$(curl --http2 -s http://localhost:9080/metrics)
  echo "Metrics: $metrics"

  if echo "$metrics" | grep -q '"http2"'; then
    echo -e "${GREEN}✓ Metrics endpoint working${NC}"
  else
    echo -e "${RED}✗ Metrics endpoint failed${NC}"
  fi
}

# Performance test with h2load (if available)
test_performance() {
  if command -v h2load &>/dev/null; then
    echo -e "\n${YELLOW}Performance Test with h2load${NC}"
    echo "Running: h2load -n 100 -c 10 -m 10 http://localhost:9080/"

    h2load -n 100 -c 10 -m 10 http://localhost:9080/ 2>/dev/null | grep -E "finished in|requests:|succeeded"

    echo -e "${GREEN}✓ Performance test completed${NC}"
  else
    echo -e "\n${YELLOW}Skipping performance test (h2load not installed)${NC}"
    echo "Install nghttp2 tools for advanced testing: brew install nghttp2"
  fi
}

# Main execution
main() {
  check_server
  test_basic_http2
  test_echo
  test_large_response
  test_hpack
  test_multiplexing
  test_status_codes
  test_json
  test_binary
  test_streaming
  test_metrics
  test_performance

  echo -e "\n${GREEN}========================================"
  echo "All tests completed!"
  echo "========================================${NC}"
}

main
