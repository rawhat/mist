import exception
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import glisten/socket.{type Socket, type SocketReason, Closed}
import glisten/socket/options
import glisten/tcp
import mist

@external(erlang, "gen_tcp", "connect")
fn connect(
  host: #(Int, Int, Int, Int),
  port: Int,
  options: List(options.ErlangTcpOption),
  timeout: Int,
) -> Result(Socket, SocketReason)

@external(erlang, "gen_server", "stop")
fn stop_server(
  pid: process.Pid,
  reason: process.ExitReason,
  timeout: Int,
) -> atom.Atom

fn with_socket(run: fn(Socket, process.Subject(String)) -> Nil) -> Nil {
  let ports = process.new_subject()
  let delivered = process.new_subject()
  let assert Ok(server) =
    mist.new(fn(request) {
      mist.websocket_with_options(
        request:,
        options: mist.WebsocketOptions(8, 10, mist.CompressionDisabled),
        on_init: fn(_) { #(Nil, None) },
        on_close: fn(_) { Nil },
        handler: fn(state, event, socket) {
          case event {
            mist.Text(text) -> {
              process.send(delivered, text)
              let assert Ok(Nil) = mist.send_text_frame(socket, text)
                as "the bounded application echoes the complete message"
              mist.continue(state)
            }
            mist.Binary(_) -> mist.continue(state)
            mist.Closed | mist.Shutdown -> mist.stop()
            mist.Custom(_) -> mist.continue(state)
          }
        },
      )
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    as "the fixture listener starts on an ephemeral port"
  let assert Ok(port) = process.receive(ports, 1000)
    as "listener publishes its port"
  let result =
    exception.rescue(fn() {
      let assert Ok(socket) =
        connect(
          #(127, 0, 0, 1),
          port,
          options.to_erl_options([
            options.Mode(options.Binary),
            options.ActiveMode(options.Passive),
          ]),
          1000,
        )
        as "the raw client connects"
      let handshake =
        "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
      let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(handshake))
        as "the client offers compression during upgrade"
      let headers = read_headers(socket, "", 8)
      assert string.contains(headers, "101 Switching Protocols")
      assert !string.contains(
        string.lowercase(headers),
        "sec-websocket-extensions:",
      )
      let outcome = exception.rescue(fn() { run(socket, delivered) })
      let _ = tcp.close(socket)
      let assert Ok(Nil) = outcome as "the socket assertions pass"
      Nil
    })
  let _ = stop_server(server.pid, process.Normal, 1000)
  let assert Ok(Nil) = result as "the bounded socket fixture completes"
  Nil
}

fn read_headers(socket: Socket, collected: String, remaining: Int) -> String {
  case string.contains(collected, "\r\n\r\n"), remaining {
    True, _ -> collected
    False, 0 -> panic as "upgrade headers exceeded the receive budget"
    False, _ -> {
      let assert Ok(bytes) = tcp.receive_timeout(socket, 0, 1000)
        as "the upgrade responds within its deadline"
      let assert Ok(text) = bit_array.to_string(bytes)
        as "HTTP headers are UTF-8"
      let collected = collected <> text
      assert string.byte_size(collected) <= 4096
      read_headers(socket, collected, remaining - 1)
    }
  }
}

fn send(socket: Socket, bytes: BitArray) -> Nil {
  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_bit_array(bytes))
    as "the test sends one frame or frame prefix"
  Nil
}

fn closed_with(socket: Socket, code: Int) -> Nil {
  let assert Ok(<<0x88, 2, actual:16>>) = tcp.receive_timeout(socket, 4, 1000)
    as "the server sends the expected close frame without waiting for payload"
  assert actual == code
  assert tcp.receive_timeout(socket, 1, 1000) == Error(Closed)
  Nil
}

pub fn oversized_declared_length_closes_before_payload_test() {
  with_socket(fn(socket, delivered) {
    send(socket, <<0x81, 0xff, 1_000_000_000:64>>)
    closed_with(socket, 1009)
    assert process.receive(delivered, 0) == Error(Nil)
  })
}

pub fn fragmented_message_limit_survives_separate_socket_reads_test() {
  with_socket(fn(socket, delivered) {
    send(socket, <<0x01, 0x86, 0, 0, 0, 0, "123456">>)

    // A ping/pong is an ordering barrier: the previous fragment has been
    // consumed before the final fragment arrives in a later socket read.
    send(socket, <<0x89, 0x80, 0, 0, 0, 0>>)
    assert tcp.receive_timeout(socket, 2, 1000) == Ok(<<0x8a, 0>>)
    send(socket, <<0x80, 0x85>>)
    closed_with(socket, 1009)
    assert process.receive(delivered, 0) == Error(Nil)
  })
}

pub fn compression_is_not_negotiated_and_rsv1_is_rejected_test() {
  with_socket(fn(socket, delivered) {
    send(socket, <<0xc1, 0x80>>)
    closed_with(socket, 1002)
    assert process.receive(delivered, 0) == Error(Nil)
  })
}

pub fn normal_messages_and_fragments_reach_the_handler_test() {
  with_socket(fn(socket, delivered) {
    send(socket, <<0x81, 0x82, 0, 0, 0, 0, "ok">>)
    assert tcp.receive_timeout(socket, 4, 1000) == Ok(<<0x81, 2, "ok">>)
    assert process.receive(delivered, 1000) == Ok("ok")
    send(socket, <<0x01, 0x86, 0, 0, 0, 0, "123456">>)
    send(socket, <<0x89, 0x80, 0, 0, 0, 0>>)
    assert tcp.receive_timeout(socket, 2, 1000) == Ok(<<0x8a, 0>>)
    send(socket, <<0x80, 0x84, 0, 0, 0, 0, "7890">>)
    assert tcp.receive_timeout(socket, 12, 1000)
      == Ok(<<0x81, 10, "1234567890">>)
    assert process.receive(delivered, 1000) == Ok("1234567890")
  })
}
