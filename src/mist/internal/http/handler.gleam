import gleam/bytes_builder.{type BytesBuilder}
import gleam/erlang.{Errored, Exited, Thrown, rescue}
import gleam/erlang/process.{type Subject}
import gleam/http as ghttp
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/iterator.{type Iterator}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glisten/internal/handler.{Close, Internal}
import glisten/socket.{type Socket, type SocketReason, Badarg}
import glisten/transport.{type Transport}
import logging
import mist/internal/encoder
import mist/internal/file
import mist/internal/http.{
  type Connection, type Handler, type ResponseData, Bytes, Chunked, File,
  ServerSentEvents, Websocket,
}

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
  |> result.map_error(log_and_error(_, conn.socket, conn.transport, req))
  |> result.then(fn(resp) {
    case resp {
      response.Response(body: Websocket(selector), ..)
      | response.Response(body: ServerSentEvents(selector), ..) -> {
        let _resp = process.select_forever(selector)
        Error(process.Normal)
      }
      response.Response(body: body, ..) as resp -> {
        case body {
          Bytes(body) -> handle_bytes_builder_body(resp, body, conn, req)
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
  req: Request(Connection),
) -> process.ExitReason {
  case error {
    Exited(msg) | Thrown(msg) | Errored(msg) -> {
      logging.log(logging.Error, string.inspect(error))
      let _ =
        response.new(500)
        |> response.set_body(
          bytes_builder.from_bit_array(<<"Internal Server Error":utf8>>),
        )
        |> response.prepend_header("content-length", "21")
        |> http.add_default_headers(True, req.method == ghttp.Head)
        |> encoder.to_bytes_builder
        |> transport.send(transport, socket, _)
      let _ = transport.close(transport, socket)
      process.Abnormal(string.inspect(msg))
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
      let _ = transport.close(conn.transport, conn.socket)
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

  transport.send(conn.transport, conn.socket, initial_payload)
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

      transport.send(conn.transport, conn.socket, encoded)
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
  let return =
    resp
    |> response.prepend_header("content-length", int.to_string(length - offset))
    |> response.set_body(bytes_builder.new())
    |> fn(r: response.Response(BytesBuilder)) {
      encoder.response_builder(resp.status, r.headers)
    }
    |> transport.send(conn.transport, conn.socket, _)
    |> result.then(fn(_) {
      file.sendfile(
        conn.transport,
        file_descriptor,
        conn.socket,
        offset,
        length,
        [],
      )
      |> result.map_error(fn(err) {
        logging.log(
          logging.Error,
          "Failed to send file: " <> string.inspect(err),
        )
        Badarg
      })
    })
    |> result.replace(Nil)

  case file.close(file_descriptor) {
    Ok(_nil) -> Nil
    Error(reason) -> {
      logging.log(
        logging.Error,
        "Failed to close file: " <> string.inspect(reason),
      )
    }
  }

  return
}

fn handle_bytes_builder_body(
  resp: response.Response(ResponseData),
  body: BytesBuilder,
  conn: Connection,
  req: Request(Connection),
) -> Result(Nil, SocketReason) {
  resp
  |> response.set_body(body)
  |> http.add_default_headers(True, req.method == ghttp.Head)
  |> encoder.to_bytes_builder
  |> transport.send(conn.transport, conn.socket, _)
}

/// Creates a standard HTTP handler service to pass to `mist.serve`
@external(erlang, "erlang", "integer_to_list")
fn integer_to_list(int int: Int, base base: Int) -> String

fn int_to_hex(int: Int) -> String {
  integer_to_list(int, 16)
}
