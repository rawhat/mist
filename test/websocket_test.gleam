import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import glisten/socket.{type Socket, type SocketReason}
import glisten/socket/options
import glisten/tcp
import gramps/websocket.{Complete, Continuation, Data, Incomplete, TextFrame}
import mist
import scaffold

const port = 8888

const websocket_key = "dGhlIHNhbXBsZSBub25jZQ=="

// RFC 6455 derives this accept key from `websocket_key`.
const accept_key = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

@external(erlang, "gen_tcp", "connect")
fn connect(
  host: #(Int, Int, Int, Int),
  port: Int,
  options: List(options.ErlangTcpOption),
  timeout: Int,
) -> Result(Socket, SocketReason)

fn connect_with_retries(retries: Int) -> Socket {
  let connected =
    connect(
      #(127, 0, 0, 1),
      port,
      options.to_erl_options([
        options.Mode(options.Binary),
        options.ActiveMode(options.Passive),
      ]),
      1000,
    )
  case connected, retries {
    Ok(socket), _ -> socket
    Error(_), 0 -> panic as "could not connect to the test server"
    Error(_), _ -> {
      // Wait and retry, as the server may still be binding its listener.
      process.sleep(10)
      connect_with_retries(retries - 1)
    }
  }
}

fn handshake(extra_headers: List(#(String, String))) -> String {
  [
    #("Host", "localhost"),
    #("Upgrade", "websocket"),
    #("Connection", "Upgrade"),
    #("Sec-WebSocket-Key", websocket_key),
    #("Sec-WebSocket-Version", "13"),
    ..extra_headers
  ]
  |> list.map(fn(header) { header.0 <> ": " <> header.1 <> "\r\n" })
  |> string.concat
  |> string.append("GET / HTTP/1.1\r\n", _)
  |> string.append("\r\n")
}

fn read_response_head(socket: Socket, received: String) -> String {
  case string.split_once(received, "\r\n\r\n") {
    Ok(#(head, _rest)) -> head
    Error(Nil) -> {
      let assert Ok(data) = tcp.receive_timeout(socket, 0, 1000)
      let assert Ok(text) = bit_array.to_string(data)
      read_response_head(socket, received <> text)
    }
  }
}

fn parse_response_head(head: String) -> #(String, List(#(String, String))) {
  let assert [status_line, ..header_lines] = string.split(head, "\r\n")
  let headers =
    list.map(header_lines, fn(line) {
      let assert Ok(#(name, value)) = string.split_once(line, ": ")
      #(string.lowercase(name), value)
    })
  #(status_line, headers)
}

/// Upgrades against `handler`, runs `after` with the 101 response's headers and
/// the still-open client socket, then closes the socket.
fn with_upgrade(
  handler: fn(Request(mist.Connection)) -> Response(mist.ResponseData),
  request_headers: List(#(String, String)),
  after: fn(List(#(String, String)), Socket) -> Nil,
) -> Nil {
  use <- scaffold.open_server(port, handler)
  let socket = connect_with_retries(50)
  let assert Ok(Nil) =
    tcp.send(socket, bytes_tree.from_string(handshake(request_headers)))

  let #(status_line, headers) =
    socket
    |> read_response_head("")
    |> parse_response_head
  assert status_line == "HTTP/1.1 101 Switching Protocols"

  after(headers, socket)
  let _ = tcp.close(socket)
  Nil
}

fn new_websocket(
  request: Request(mist.Connection),
) -> mist.WebsocketBuilder(Nil, Nil) {
  mist.new_websocket(
    request:,
    handler: fn(state, _message, _connection) { mist.continue(state) },
    on_init: fn(_connection) { #(Nil, None) },
  )
}

pub fn it_sends_supplied_headers_with_the_handshake_headers_test() {
  use headers, _socket <- with_upgrade(
    fn(request) {
      new_websocket(request)
      |> mist.websocket_header("X-Session", "abc")
      |> mist.start_websocket
    },
    [],
  )

  assert list.key_find(headers, "x-session") == Ok("abc")
  assert list.key_find(headers, "upgrade") == Ok("websocket")
  assert list.key_find(headers, "connection") == Ok("Upgrade")
  assert list.key_find(headers, "sec-websocket-accept") == Ok(accept_key)
}

pub fn it_sends_a_header_chosen_from_the_request_test() {
  use headers, _socket <- with_upgrade(
    fn(request) {
      let protocol =
        request
        |> request.get_header("sec-websocket-protocol")
        |> result.try(fn(offered) {
          offered
          |> string.split(", ")
          |> list.find(fn(protocol) { protocol == "ocpp1.6" })
        })
        |> result.unwrap("none")
      new_websocket(request)
      |> mist.websocket_header("sec-websocket-protocol", protocol)
      |> mist.start_websocket
    },
    [#("Sec-WebSocket-Protocol", "ocpp2.0, ocpp1.6")],
  )

  assert list.key_find(headers, "sec-websocket-protocol") == Ok("ocpp1.6")
}

pub fn it_sends_a_repeated_header_once_per_value_test() {
  use headers, _socket <- with_upgrade(
    fn(request) {
      new_websocket(request)
      |> mist.websocket_header("set-cookie", "a=1")
      |> mist.websocket_header("set-cookie", "b=2")
      |> mist.start_websocket
    },
    [],
  )

  assert list.key_filter(headers, "set-cookie") == ["a=1", "b=2"]
}

pub fn it_keeps_its_own_handshake_headers_test() {
  use headers, _socket <- with_upgrade(
    fn(request) {
      new_websocket(request)
      |> mist.websocket_header("Upgrade", "h2c")
      |> mist.websocket_header("Connection", "close")
      |> mist.websocket_header("Sec-WebSocket-Accept", "forged")
      |> mist.websocket_header("Sec-WebSocket-Extensions", "permessage-deflate")
      |> mist.start_websocket
    },
    [],
  )

  assert list.key_filter(headers, "upgrade") == ["websocket"]
  assert list.key_filter(headers, "connection") == ["Upgrade"]
  assert list.key_filter(headers, "sec-websocket-accept") == [accept_key]
  assert list.key_filter(headers, "sec-websocket-extensions") == []
}

pub fn it_calls_on_close_when_the_client_disconnects_test() {
  let closed = process.new_subject()
  use _headers, socket <- with_upgrade(
    fn(request) {
      new_websocket(request)
      |> mist.websocket_on_close(fn(_state) { process.send(closed, Nil) })
      |> mist.start_websocket
    },
    [],
  )

  let assert Ok(Nil) = tcp.close(socket)
  assert process.receive(closed, 1000) == Ok(Nil)
}

pub fn it_upgrades_without_supplied_headers_test() {
  use headers, _socket <- with_upgrade(
    fn(request) {
      mist.websocket(
        request:,
        handler: fn(state, _message, _connection) { mist.continue(state) },
        on_init: fn(_connection) { #(Nil, None) },
        on_close: fn(_state) { Nil },
      )
    },
    [],
  )

  assert list.key_find(headers, "sec-websocket-accept") == Ok(accept_key)
}

pub fn it_should_combine_continuation_frames_test() {
  let one = <<"Hello":utf8>>
  let two = <<", ":utf8>>
  let three = <<"world!":utf8>>
  let messages = [
    Incomplete(Data(TextFrame(one))),
    Incomplete(Continuation(bit_array.byte_size(two), two)),
    Complete(Continuation(bit_array.byte_size(three), three)),
  ]

  let combined = <<"Hello, world!":utf8>>

  assert websocket.aggregate_frames(messages, None, [])
    == Ok([Data(TextFrame(combined))])
}
