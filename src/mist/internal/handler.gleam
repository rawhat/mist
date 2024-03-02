import gleam/bytes_builder.{type BytesBuilder}
import gleam/dynamic
import gleam/erlang.{Errored, Exited, Thrown, rescue}
import gleam/erlang/process.{type ProcessDown, type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/iterator.{type Iterator}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import glisten/handler.{Close, Internal}
import glisten/socket.{type Socket, type SocketReason, Badarg}
import glisten/socket/transport.{type Transport}
import glisten.{type Loop, type Message, Packet}
import mist/internal/encoder
import mist/internal/file
import mist/internal/http.{
  type Connection, type DecodeError, Connection, DiscardPacket, Initial,
}
import mist/internal/logger

pub type ResponseData {
  Websocket(Selector(ProcessDown))
  Bytes(BytesBuilder)
  Chunked(Iterator(BytesBuilder))
  File(descriptor: file.FileDescriptor, offset: Int, length: Int)
}

pub type Handler =
  fn(Request(Connection)) -> response.Response(ResponseData)

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

const stop_normal = actor.Stop(process.Normal)

pub type State {
  State(idle_timer: Option(process.Timer))
}

pub fn new_state() -> State {
  State(None)
}

/// This is a more flexible handler. It will allow you to upgrade a connection
/// to a websocket connection, or deal with a regular HTTP req->resp workflow.
pub fn with_func(handler: Handler) -> Loop(user_message, State) {
  fn(msg, state: State, conn: glisten.Connection(user_message)) {
    let assert Packet(msg) = msg
    let sender = conn.subject
    let conn =
      Connection(
        body: Initial(<<>>),
        socket: conn.socket,
        transport: conn.transport,
        client_ip: conn.client_ip,
      )
    {
      let _ = case state.idle_timer {
        Some(t) -> process.cancel_timer(t)
        _ -> process.TimerNotFound
      }
      msg
      |> http.parse_request(conn)
      |> result.map_error(fn(err) {
        case err {
          DiscardPacket -> Nil
          _ -> {
            logger.error(err)
            let _ = conn.transport.close(conn.socket)
            Nil
          }
        }
      })
      |> result.replace_error(stop_normal)
      |> result.then(fn(req) {
        rescue(fn() { handler(req) })
        |> result.map(fn(resp) { #(req, resp) })
        |> result.map_error(log_and_error(_, conn.socket, conn.transport))
      })
      |> result.map(fn(req_resp) {
        let #(_req, response) = req_resp
        case response {
          response.Response(body: Bytes(body), ..) as resp ->
            handle_bytes_builder_body(resp, body, conn)
            |> result.map(fn(_res) { close_or_set_timer(resp, conn, sender) })
            |> result.replace_error(stop_normal)
            |> result.unwrap_both
          response.Response(body: Chunked(body), ..) as resp -> {
            handle_chunked_body(resp, body, conn)
            |> result.map(fn(_res) { close_or_set_timer(resp, conn, sender) })
            |> result.replace_error(stop_normal)
            |> result.unwrap_both
          }
          response.Response(body: File(..), ..) as resp ->
            handle_file_body(resp, conn)
            |> result.map(fn(_res) { close_or_set_timer(resp, conn, sender) })
            |> result.replace_error(stop_normal)
            |> result.unwrap_both
          response.Response(body: Websocket(selector), ..) -> {
            let _resp = process.select_forever(selector)
            actor.Stop(process.Normal)
          }
        }
      })
    }
    |> result.unwrap_both
  }
}

fn log_and_error(
  error: erlang.Crash,
  socket: Socket,
  transport: Transport,
) -> actor.Next(Message(user_message), State) {
  case error {
    Exited(msg) | Thrown(msg) | Errored(msg) -> {
      logger.error(error)
      response.new(500)
      |> response.set_body(
        bytes_builder.from_bit_array(<<"Internal Server Error":utf8>>),
      )
      |> response.prepend_header("content-length", "21")
      |> http.add_default_headers
      |> encoder.to_bytes_builder
      |> transport.send(socket, _)
      let _ = transport.close(socket)
      actor.Stop(process.Abnormal(dynamic.unsafe_coerce(msg)))
    }
  }
}

fn close_or_set_timer(
  resp: response.Response(ResponseData),
  conn: Connection,
  sender: Subject(handler.Message(user_message)),
) -> actor.Next(Message(user_message), State) {
  // If the handler explicitly says to close the connection, we should
  // probably listen to them
  case response.get_header(resp, "connection") {
    Ok("close") -> {
      let _ = conn.transport.close(conn.socket)
      stop_normal
    }
    _ -> {
      // TODO:  this should be a configuration
      let timer = process.send_after(sender, 10_000, Internal(Close))
      actor.continue(State(idle_timer: Some(timer)))
    }
  }
}

fn handle_bytes_builder_body(
  resp: response.Response(ResponseData),
  body: BytesBuilder,
  conn: Connection,
) -> Result(Nil, SocketReason) {
  resp
  |> response.set_body(body)
  |> http.add_default_headers
  |> encoder.to_bytes_builder
  |> conn.transport.send(conn.socket, _)
}

fn int_to_hex(int: Int) -> String {
  integer_to_list(int, 16)
}

fn handle_chunked_body(
  resp: response.Response(ResponseData),
  body: Iterator(BytesBuilder),
  conn: Connection,
) -> Result(Nil, SocketReason) {
  let headers = [#("transfer-encoding", "chunked"), ..resp.headers]
  let initial_payload = encoder.response_builder(resp.status, headers)

  conn.transport.send(conn.socket, initial_payload)
  |> result.then(fn(_ok) {
    body
    |> iterator.append(iterator.from_list([bytes_builder.new()]))
    |> iterator.try_fold(Nil, fn(_prev, chunk) {
      let size = bytes_builder.byte_size(chunk)
      let encoded =
        size
        |> int_to_hex
        |> bytes_builder.from_string
        |> bytes_builder.append_string("\r\n")
        |> bytes_builder.append_builder(chunk)
        |> bytes_builder.append_string("\r\n")

      conn.transport.send(conn.socket, encoded)
    })
  })
  |> result.replace(Nil)
}

fn handle_file_body(
  resp: response.Response(ResponseData),
  conn: Connection,
) -> Result(Nil, SocketReason) {
  let assert File(file_descriptor, offset, length) = resp.body
  resp
  |> response.prepend_header("content-length", int.to_string(length - offset))
  |> response.set_body(bytes_builder.new())
  |> fn(r: response.Response(BytesBuilder)) {
    encoder.response_builder(resp.status, r.headers)
  }
  |> conn.transport.send(conn.socket, _)
  |> result.then(fn(_) {
    file.sendfile(
      conn.transport,
      file_descriptor,
      conn.socket,
      offset,
      length,
      [],
    )
    |> result.map_error(fn(err) { logger.error(#("Failed to send file", err)) })
    |> result.replace_error(Badarg)
  })
  |> result.replace(Nil)
}

/// Creates a standard HTTP handler service to pass to `mist.serve`
@external(erlang, "erlang", "integer_to_list")
fn integer_to_list(int int: Int, base base: Int) -> String
