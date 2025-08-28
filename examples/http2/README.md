# HTTP/2 Comprehensive Example for Mist

This example demonstrates all HTTP/2 capabilities supported by the Mist web server, including **full H2C (HTTP/2 cleartext) upgrade support**.

## Features Demonstrated

### Core HTTP/2 Features
- ✅ **H2C Upgrade**: Complete HTTP/1.1 → HTTP/2 upgrade mechanism
- ✅ **Multiplexing**: Multiple requests/responses over a single connection
- ✅ **Header Compression (HPACK)**: Efficient header encoding
- ✅ **Flow Control**: Window-based flow control for streams
- ✅ **Binary Framing**: Binary protocol instead of text-based HTTP/1.1
- ✅ **Stream Prioritization**: Request prioritization (client-dependent)

### Configuration Options
- Custom max concurrent streams
- Configurable initial window size
- Adjustable max frame size
- Optional max header list size

## Running the Example

### 1. Install Dependencies
```bash
cd examples/http2
gleam deps download
gleam build
```

### 2. Start the Server
```bash
gleam run
```

This starts two servers:
- **HTTP/2 (h2c)** on http://localhost:9080 - HTTP/2 over cleartext with H2C upgrade
- **HTTP/2 (TLS)** on https://localhost:8443 - HTTP/2 over TLS (requires certificates)

### 3. Generate TLS Certificates (for HTTPS)
```bash
./generate_certs.sh
```

## Available Endpoints

| Method | Path | Description | HTTP/2 Feature Tested |
|--------|------|-------------|----------------------|
| GET | `/` | Server info and capabilities | Basic connection |
| GET/POST | `/echo` | Echo request details | Header inspection |
| GET | `/stream` | Streaming response | Chunked data |
| GET | `/large` | 100KB response | Flow control |
| GET | `/headers` | Response with 50+ headers | HPACK compression |
| GET | `/delay/{seconds}` | Delayed response (max 5s) | Multiplexing |
| GET | `/status/{code}` | Return specific status | Status handling |
| GET/POST | `/json` | JSON response/echo | Content types |
| GET | `/binary` | Binary data download | Binary frames |
| GET | `/metrics` | Server metrics | Monitoring |

## Testing

### Automated Test Suite

**Unit Tests** (Gleam):
```bash
gleam test
```

**H2C Upgrade Integration Tests**:
```bash
./test_h2c_upgrade.sh
```

**Full HTTP/2 Feature Tests**:
```bash
./test_http2.sh
```

### Manual Testing Examples

#### 1. Basic HTTP/2 Request
```bash
# H2C upgrade (HTTP/1.1 → HTTP/2)
curl --http2 -v http://localhost:9080/

# Direct HTTP/2 (prior knowledge)
curl --http2-prior-knowledge -v http://localhost:9080/

# HTTP/2 over TLS (accept self-signed cert)
curl --http2 -k -v https://localhost:8443/
```

#### 2. Test Multiplexing
```bash
# Send 5 parallel requests with different delays
# Should complete in ~3 seconds (not 9 seconds sequentially)
curl --http2-prior-knowledge --parallel --parallel-max 5 \
  http://localhost:9080/delay/1 \
  http://localhost:9080/delay/2 \
  http://localhost:9080/delay/3 \
  http://localhost:9080/delay/1 \
  http://localhost:9080/delay/2
```

#### 3. Test Flow Control
```bash
# Download large response
curl --http2-prior-knowledge -v http://localhost:9080/large > /dev/null

# Watch for flow control frames in verbose output
```

#### 4. Test HPACK Compression
```bash
# Get response with many headers
curl --http2-prior-knowledge -I http://localhost:9080/headers

# Headers are compressed using HPACK
```

#### 5. Test Different Content Types
```bash
# JSON response
curl --http2-prior-knowledge http://localhost:9080/json | jq .

# Binary data
curl --http2-prior-knowledge --output data.bin http://localhost:9080/binary

# Server-sent events style
curl --http2-prior-knowledge http://localhost:9080/stream
```

#### 6. POST Request with Data
```bash
# Echo POST data
curl --http2-prior-knowledge -X POST -d '{"test": "data"}' \
  -H "Content-Type: application/json" \
  http://localhost:9080/echo
```

## Advanced Testing with nghttp2

If you have nghttp2 tools installed:

### Installation
```bash
# macOS
brew install nghttp2

# Ubuntu/Debian
apt-get install nghttp2-client

# From source
git clone https://github.com/nghttp2/nghttp2.git
cd nghttp2
./configure && make && sudo make install
```

### nghttp2 Testing Commands

#### Detailed Protocol Information
```bash
# See detailed HTTP/2 frames
nghttp -v http://localhost:9080/

# With custom settings
nghttp -v --window-bits=20 --max-concurrent-streams=100 \
  http://localhost:9080/
```

#### Performance Testing with h2load
```bash
# Basic load test
h2load -n 1000 -c 10 -m 100 http://localhost:9080/

# Test with multiple URIs
h2load -n 1000 -c 10 -m 50 \
  http://localhost:9080/ \
  http://localhost:9080/json \
  http://localhost:9080/metrics

# Extended test with timing
h2load -n 10000 -c 100 -m 10 --duration=30 \
  http://localhost:9080/
```

## Browser Testing

Modern browsers automatically negotiate HTTP/2 when available.

1. Open Chrome/Firefox/Safari
2. Open Developer Tools (F12)
3. Go to Network tab
4. Visit http://localhost:9080/
5. Check the "Protocol" column - should show "h2" for HTTP/2

### Chrome Specific
- chrome://net-internals/#http2 - View active HTTP/2 sessions
- chrome://net-internals/#events - See detailed protocol events

### Firefox Specific
- about:networking#http2 - View HTTP/2 connections

## Configuration Guide

### Server Configuration
```gleam
handler
|> mist.new()
|> mist.with_http2()  // Enable with defaults
|> mist.http2_max_concurrent_streams(1000)  // Max parallel streams
|> mist.http2_initial_window_size(1_048_576)  // 1MB flow control window
|> mist.http2_max_frame_size(32_768)  // 32KB max frame
|> mist.http2_max_header_list_size(16_384)  // 16KB header limit
|> mist.start
```

### Configuration Parameters

| Parameter | Default | Description | Recommendation |
|-----------|---------|-------------|----------------|
| max_concurrent_streams | 100 | Max parallel requests | 100-1000 for typical servers |
| initial_window_size | 65,535 | Flow control window (bytes) | 65KB-2MB depending on bandwidth |
| max_frame_size | 16,384 | Max HTTP/2 frame size | 16KB-1MB (16KB is standard) |
| max_header_list_size | None | Max header size | 8KB-16KB for most applications |

## Monitoring and Debugging

### Server Metrics Endpoint
```bash
curl --http2-prior-knowledge http://localhost:9080/metrics | jq .
```

### Logging
The server logs HTTP/2 events. Set log level in your application:
```gleam
logging.configure()
logging.set_level(logging.Debug)
```

### Common Issues

1. **Connection not upgrading to HTTP/2**
   - Ensure client supports HTTP/2
   - Check with `curl --http2 -v` for protocol negotiation
   - For h2c (cleartext), client must send upgrade header

2. **TLS certificate errors**
   - Generate certificates with `./generate_certs.sh`
   - Use `-k` flag with curl to accept self-signed certs
   - For production, use proper certificates

3. **Performance issues**
   - Adjust window sizes for your bandwidth
   - Increase max_concurrent_streams for high load
   - Monitor with h2load for bottlenecks

## HTTP/2 vs HTTP/1.1 Comparison

| Feature | HTTP/1.1 | HTTP/2 |
|---------|----------|---------|
| Protocol | Text | Binary |
| Multiplexing | No (uses pipelining) | Yes |
| Header Compression | No | Yes (HPACK) |
| Server Push | No | Yes (disabled in this example) |
| Flow Control | TCP only | Stream + Connection level |
| Connections Needed | Multiple | Single |

## Further Resources

- [HTTP/2 RFC 7540](https://tools.ietf.org/html/rfc7540)
- [HPACK RFC 7541](https://tools.ietf.org/html/rfc7541)
- [nghttp2 Documentation](https://nghttp2.org/documentation/)
- [Chrome HTTP/2 Debugging](https://developers.google.com/web/fundamentals/performance/http2)
- [Mist Documentation](https://github.com/rawhat/mist)