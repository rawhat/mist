import gleam/dynamic
import gleam/int
import gleam/bytes_builder.{type BytesBuilder}
import gleam/iterator.{type Iterator}
import gleam/erlang/process.{type Subject}
import gleam/erlang.{Errored, Exited, Thrown, rescue}
import gleam/option.{type Option, None, Some}
import mist/internal/http.{
  type Connection, type Handler, type ResponseData, Bytes, Chunked, File,
  Websocket,
}
import gleam/result
import mist/internal/logger
import gleam/http/request.{type Request}
import glisten/handler.{Close, Internal}
import glisten/socket.{type Socket, type SocketReason, Badarg}
import glisten/socket/transport.{type Transport}
import gleam/http/response
import mist/internal/encoder
import mist/internal/file

pub type State {
  State(idle_timer: Option(process.Timer))
}

pub fn initial_state() -> State {
  State(idle_timer: None)
}

pub fn call(
  req: Request(Connection),
  handler: Handler,
  conn: Connection,
  sender: Subject(handler.Message(user_message)),
) -> Result(State, process.ExitReason) {
  rescue(fn() { handler(req) })
  |> result.map_error(log_and_error(_, conn.socket, conn.transport))
  |> result.then(fn(resp) {
    case resp {
      response.Response(body: Websocket(selector), ..) -> {
        let _resp = process.select_forever(selector)
        Error(process.Normal)
      }
      response.Response(body: body, ..) as resp -> {
        case body {
          Bytes(body) -> handle_bytes_builder_body(resp, body, conn)
          Chunked(body) -> handle_chunked_body(resp, body, conn)
          File(..) -> handle_file_body(resp, body, conn)
          _ -> panic as "This shouldn't ever happen 🤞"
        }
        |> result.replace_error(process.Normal)
        |> result.then(fn(_res) { close_or_set_timer(resp, conn, sender) })
      }
    }
  })
}

fn log_and_error(
  error: erlang.Crash,
  socket: Socket,
  transport: Transport,
) -> process.ExitReason {
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
      process.Abnormal(dynamic.unsafe_coerce(msg))
    }
  }
}

fn close_or_set_timer(
  resp: response.Response(ResponseData),
  conn: Connection,
  sender: Subject(handler.Message(user_message)),
) -> Result(State, process.ExitReason) {
  // If the handler explicitly says to close the connection, we should
  // probably listen to them
  case response.get_header(resp, "connection") {
    Ok("close") -> {
      let _ = conn.transport.close(conn.socket)
      Error(process.Normal)
    }
    _ -> {
      // TODO:  this should be a configuration
      let timer = process.send_after(sender, 10_000, Internal(Close))
      Ok(State(idle_timer: Some(timer)))
    }
  }
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
  body: ResponseData,
  conn: Connection,
) -> Result(Nil, SocketReason) {
  let assert File(file_descriptor, offset, length) = body
  resp
  |> response.prepend_header("content-length", int.to_string(length - offset))
  |> response.set_body(bytes_builder.new())
  |> fn(r: response.Response(BytesBuilder)) {
    encoder.response_builder(resp.status, r.headers)
  }
  |> conn.transport.send(conn.socket, _)
  |> result.then(fn(_) {
    file.sendfile(file_descriptor, conn.socket, offset, length, [])
    |> result.map_error(fn(err) { logger.error(#("Failed to send file", err)) })
    |> result.replace_error(Badarg)
  })
  |> result.replace(Nil)
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

/// Creates a standard HTTP handler service to pass to `mist.serve`
@external(erlang, "erlang", "integer_to_list")
fn integer_to_list(int int: Int, base base: Int) -> String

fn int_to_hex(int: Int) -> String {
  integer_to_list(int, 16)
}
