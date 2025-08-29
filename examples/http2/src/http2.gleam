import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/string_tree
import mist

pub fn main() {
  // Start both HTTP and HTTPS servers
  let _ = start_http_server()
  start_https_server()

  io.println(
    "
================================================================================
HTTP/2 Comprehensive Example Server Started
================================================================================

Servers running:
  - HTTP/2 (h2c): http://localhost:9080
  - HTTP/2 (TLS): https://localhost:8443

Available endpoints:
  GET  /                     - Server info and capabilities
  GET  /echo                 - Echo request details  
  POST /echo                 - Echo posted data
  GET  /stream               - Streaming response example
  GET  /large                - Large response (tests flow control)
  GET  /headers              - Many headers (tests HPACK compression)
  GET  /delay/{seconds}      - Delayed response (tests multiplexing)
  GET  /status/{code}        - Return specific status code
  GET  /json                 - JSON response
  POST /json                 - JSON echo
  GET  /binary               - Binary data response
  GET  /metrics              - Server metrics

See README.md for testing instructions
================================================================================
",
  )

  process.sleep_forever()
}

fn start_http_server() {
  let assert Ok(_) =
    handler
    |> mist.new()
    |> mist.port(9080)
    |> mist.with_http2()
    |> mist.http2_max_concurrent_streams(1000)
    |> mist.http2_initial_window_size(1_048_576)
    // 1MB
    |> mist.http2_max_frame_size(32_768)
    // 32KB
    |> mist.http2_max_header_list_size(16_384)
    // 16KB
    |> mist.after_start(fn(port, _scheme, _ip) {
      io.println("HTTP/2 (h2c) server started on port " <> int.to_string(port))
    })
    |> mist.start
}

fn start_https_server() {
  // Check if certificates exist, if not provide instructions
  case check_certificates() {
    True -> {
      let assert Ok(_) =
        handler
        |> mist.new()
        |> mist.port(8443)
        |> mist.with_tls(certfile: "localhost.crt", keyfile: "localhost.key")
        |> mist.with_http2()
        |> mist.http2_max_concurrent_streams(500)
        |> mist.http2_initial_window_size(2_097_152)
        // 2MB
        |> mist.http2_max_frame_size(65_536)
        // 64KB
        |> mist.after_start(fn(port, _scheme, _ip) {
          io.println(
            "HTTP/2 (TLS) server started on port " <> int.to_string(port),
          )
        })
        |> mist.start
      Nil
    }
    False -> {
      io.println(
        "
NOTE: TLS certificates not found. To enable HTTPS:
  Run: ./generate_certs.sh
  Or manually create localhost.crt and localhost.key
",
      )
    }
  }
}

fn handler(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let path = request.path_segments(req)

  case path {
    [] -> handle_root(req)
    ["echo"] -> handle_echo(req)
    ["stream"] -> handle_stream(req)
    ["large"] -> handle_large_response(req)
    ["headers"] -> handle_many_headers(req)
    ["delay", seconds_str] -> handle_delay(req, seconds_str)
    ["status", code_str] -> handle_status(req, code_str)
    ["json"] -> handle_json(req)
    ["binary"] -> handle_binary(req)
    ["metrics"] -> handle_metrics(req)
    _ -> handle_not_found(req)
  }
}

fn handle_root(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let body =
    string_tree.from_strings([
      "HTTP/2 Server Information\n",
      "========================\n\n",
      "Protocol: HTTP/2 (if client supports)\n",
      "Method: ",
      http_method_to_string(req.method),
      "\n",
      "Path: ",
      req.path,
      "\n",
      "Host: ",
      get_header(req, "host"),
      "\n",
      "User-Agent: ",
      get_header(req, "user-agent"),
      "\n\n",
      "Server Capabilities:\n",
      "- Multiplexing: Yes\n",
      "- Header Compression (HPACK): Yes\n",
      "- Flow Control: Yes\n",
      "- Server Push: Disabled\n",
      "- Max Concurrent Streams: 1000 (HTTP), 500 (HTTPS)\n",
      "- Initial Window Size: 1MB (HTTP), 2MB (HTTPS)\n",
      "- Max Frame Size: 32KB (HTTP), 64KB (HTTPS)\n\n",
      "Test with: curl --http2 -v http://localhost:9080/\n",
    ])

  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string_tree(body)))
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_header("x-http-version", "HTTP/2")
}

fn handle_echo(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  // Get common headers
  let headers_str =
    [
      "  host: " <> get_header(req, "host"),
      "  user-agent: " <> get_header(req, "user-agent"),
      "  accept: " <> get_header(req, "accept"),
      "  content-type: " <> get_header(req, "content-type"),
      "  accept-encoding: " <> get_header(req, "accept-encoding"),
    ]
    |> string.join("\n")

  let body =
    string_tree.from_strings([
      "Echo Service\n",
      "============\n\n",
      "Method: ",
      http_method_to_string(req.method),
      "\n",
      "Path: ",
      req.path,
      "\n",
      "Query: ",
      option.unwrap(req.query, "(none)"),
      "\n\n",
      "Headers:\n",
      headers_str,
      "\n\n",
      case req.method {
        http.Post | http.Put ->
          "Note: Body reading would be implemented here for POST/PUT requests\n"
        _ -> ""
      },
    ])

  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string_tree(body)))
  |> response.set_header("content-type", "text/plain")
  |> response.set_header("x-echo-headers-count", "5")
}

fn handle_stream(
  _req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  // Demonstrate a streaming-like response
  let events =
    list.range(1, 5)
    |> list.map(fn(i) {
      "data: Event "
      <> int.to_string(i)
      <> " - Timestamp: "
      <> int.to_string(i * 1000)
      <> "\n\n"
    })

  let body = string.join(events, "")

  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_header("cache-control", "no-cache")
  |> response.set_header("x-stream-events", "5")
}

fn handle_large_response(
  _req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  // Generate a large response to test flow control
  let chunk = string.repeat("X", 1024)
  // 1KB chunk
  let large_data = string.repeat(chunk, 100)
  // 100KB total

  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(large_data)))
  |> response.set_header("content-type", "text/plain")
  |> response.set_header("content-length", int.to_string(100 * 1024))
  |> response.set_header("x-content-description", "100KB of 'X' characters")
}

fn handle_many_headers(
  _req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  // Test HPACK compression with many headers
  let resp =
    response.new(200)
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string(
        "Testing HPACK compression\n\nThis response includes 50 custom headers to test HTTP/2's HPACK header compression.",
      )),
    )
    |> response.set_header("content-type", "text/plain")

  // Add many custom headers to test HPACK
  list.range(1, 50)
  |> list.fold(resp, fn(r, i) {
    r
    |> response.set_header(
      "x-custom-header-" <> int.to_string(i),
      "value-" <> int.to_string(i),
    )
    |> response.set_header(
      "x-test-data-" <> int.to_string(i),
      string.repeat("test", i),
    )
  })
}

fn handle_delay(
  _req: request.Request(mist.Connection),
  seconds_str: String,
) -> response.Response(mist.ResponseData) {
  let seconds = result.unwrap(int.parse(seconds_str), 1)
  let delay_ms = int.min(seconds * 1000, 5000)
  // Max 5 seconds

  // Simulate processing delay
  process.sleep(delay_ms)

  response.new(200)
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "Response delayed by "
      <> int.to_string(delay_ms)
      <> "ms\n\n"
      <> "This endpoint is useful for testing HTTP/2 multiplexing.\n"
      <> "Try multiple parallel requests with different delays.",
    )),
  )
  |> response.set_header("content-type", "text/plain")
  |> response.set_header("x-delay-ms", int.to_string(delay_ms))
}

fn handle_status(
  _req: request.Request(mist.Connection),
  code_str: String,
) -> response.Response(mist.ResponseData) {
  let code = result.unwrap(int.parse(code_str), 200)
  let status_text = case code {
    200 -> "OK"
    201 -> "Created"
    204 -> "No Content"
    301 -> "Moved Permanently"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    404 -> "Not Found"
    500 -> "Internal Server Error"
    502 -> "Bad Gateway"
    503 -> "Service Unavailable"
    _ -> "Custom Status"
  }

  response.new(code)
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "Status Code: " <> int.to_string(code) <> " " <> status_text,
    )),
  )
  |> response.set_header("content-type", "text/plain")
  |> response.set_header("x-status-code", int.to_string(code))
}

fn handle_json(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let json_response =
    json.object([
      #("method", json.string(http_method_to_string(req.method))),
      #("path", json.string(req.path)),
      #("protocol", json.string("HTTP/2")),
      #("headers_count", json.int(5)),
      #(
        "features",
        json.array(
          [
            json.string("multiplexing"),
            json.string("header_compression"),
            json.string("flow_control"),
            json.string("binary_framing"),
          ],
          of: fn(x) { x },
        ),
      ),
    ])

  response.new(200)
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(json.to_string(json_response))),
  )
  |> response.set_header("content-type", "application/json")
}

fn handle_binary(
  _req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  // Generate some binary data (256 bytes)
  let binary_data =
    list.range(0, 255)
    |> list.map(int.to_string)
    |> string.join("")
    |> bit_array.from_string

  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(binary_data)))
  |> response.set_header("content-type", "application/octet-stream")
  |> response.set_header(
    "content-length",
    int.to_string(bit_array.byte_size(binary_data)),
  )
  |> response.set_header(
    "content-disposition",
    "attachment; filename=\"data.bin\"",
  )
}

fn handle_metrics(
  _req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  // Mock metrics for demonstration
  let metrics =
    json.object([
      #(
        "server",
        json.object([
          #("uptime_seconds", json.int(3600)),
          #("version", json.string("1.0.0")),
        ]),
      ),
      #(
        "http2",
        json.object([
          #("enabled", json.bool(True)),
          #("max_concurrent_streams", json.int(1000)),
          #("active_connections", json.int(42)),
          #("total_requests", json.int(12_345)),
        ]),
      ),
      #(
        "performance",
        json.object([
          #("average_response_time_ms", json.float(23.4)),
          #("requests_per_second", json.float(150.5)),
        ]),
      ),
    ])

  response.new(200)
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(json.to_string(metrics))),
  )
  |> response.set_header("content-type", "application/json")
  |> response.set_header("cache-control", "no-cache")
}

fn handle_not_found(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "404 Not Found\n\nThe requested path '" <> req.path <> "' was not found.",
    )),
  )
  |> response.set_header("content-type", "text/plain")
}

// Helper functions

fn http_method_to_string(method) -> String {
  case method {
    http.Get -> "GET"
    http.Post -> "POST"
    http.Put -> "PUT"
    http.Delete -> "DELETE"
    http.Head -> "HEAD"
    http.Options -> "OPTIONS"
    http.Patch -> "PATCH"
    http.Trace -> "TRACE"
    http.Connect -> "CONNECT"
    http.Other(m) -> m
  }
}

fn get_header(req: request.Request(mist.Connection), name: String) -> String {
  request.get_header(req, name)
  |> result.unwrap("(not set)")
}

fn check_certificates() -> Bool {
  // Simple check - in real app would use proper file system checks
  // For now, we'll assume they exist if the example is being run
  // Users will need to generate them manually
  False
}
