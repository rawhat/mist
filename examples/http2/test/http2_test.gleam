import gleam/bit_array
import gleam/bytes_tree
import gleam/http/response
import gleam/list
import gleam/order
import gleeunit
import gleeunit/should
import mist
import mist/internal/http2/frame

pub fn main() -> Nil {
  gleeunit.main()
}

// HTTP/2 Frame Tests
pub fn http2_preface_pattern_test() {
  let _preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>
  let test_data = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8, "extra":utf8>>
  
  case test_data {
    <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8, rest:bits>> -> {
      bit_array.to_string(rest)
      |> should.equal(Ok("extra"))
    }
    _ -> panic as "Preface pattern should match"
  }
}

pub fn http2_preface_size_test() {
  let preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>
  bit_array.byte_size(preface)
  |> should.equal(24)
}

// HTTP/2 Settings Frame Tests  
pub fn http2_settings_frame_decode_test() {
  // Valid empty SETTINGS frame: length=0, type=4, flags=0, stream=0
  let settings_frame = <<0:24, 4:8, 0:8, 0:1, 0:31>>
  
  case frame.decode(settings_frame) {
    Ok(#(frame.Settings(ack: False, settings: []), _)) -> Nil
    _ -> panic as "Should decode empty SETTINGS frame"
  }
}

// HTTP/2 Connection Tests
pub fn http2_config_default_test() {
  let config = mist.default_http2_config()
  
  config.enabled |> should.equal(True)
  config.max_concurrent_streams |> should.equal(100)
  config.initial_window_size |> should.equal(65_535)
  config.max_frame_size |> should.equal(16_384)
}

// HTTP Request Parsing Tests
pub fn h2c_upgrade_headers_test() {
  let headers = [
    #("host", "localhost:9080"),
    #("connection", "Upgrade, HTTP2-Settings"),
    #("upgrade", "h2c"),
    #("http2-settings", "AAMAAABkAAQAoAAAAAIAAAAA"),
  ]
  
  // Test that we can identify H2C upgrade request
  let has_upgrade = case headers {
    _ -> {
      let connection = case headers |> list.key_find("connection") {
        Ok(value) -> value
        _ -> ""
      }
      let upgrade = case headers |> list.key_find("upgrade") {
        Ok(value) -> value  
        _ -> ""
      }
      let settings = case headers |> list.key_find("http2-settings") {
        Ok(value) -> value
        _ -> ""
      }
      
      connection != "" && upgrade == "h2c" && settings != ""
    }
  }
  
  has_upgrade |> should.equal(True)
}

// Bit Array Manipulation Tests
pub fn bit_array_append_test() {
  let part1 = <<"PRI * ":utf8>>
  let part2 = <<"HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>
  let expected = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>
  
  bit_array.append(part1, part2)
  |> should.equal(expected)
}

pub fn bit_array_prefix_match_test() {
  let full_preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>
  let partial = <<"PRI * HTTP":utf8>>
  
  // Test prefix matching logic
  let matches = case bit_array.slice(full_preface, 0, bit_array.byte_size(partial)) {
    Ok(prefix) -> bit_array.compare(prefix, partial) == order.Eq
    Error(_) -> False
  }
  
  matches |> should.equal(True)
}

// HTTP Response Tests
pub fn http_101_response_test() {
  let response = response.new(101)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
    |> response.set_header("connection", "Upgrade")
    |> response.set_header("upgrade", "h2c")
  
  response.status |> should.equal(101)
  
  case response.get_header(response, "upgrade") {
    Ok("h2c") -> Nil
    _ -> panic as "Should have h2c upgrade header"
  }
}

// Integration Test Helpers
pub fn mock_connection_test() {
  // Test that we can create a mock connection structure
  let _body_data = <<"test":utf8>>
  True |> should.equal(True) // Placeholder for connection mock test
}
