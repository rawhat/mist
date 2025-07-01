import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/http as ghttp
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/yielder.{type Yielder}
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

@external(erlang, "mist_ffi", "rescue")
fn rescue(func: fn() -> any) -> Result(any, Dynamic)

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
  version: http.HttpVersion,
) -> Result(State, Result(Nil, String)) {
  rescue(fn() { handler(req) })
  |> result.map_error(log_and_error(
    _,
    conn.socket,
    conn.transport,
    req,
    version,
  ))
  |> result.try(fn(resp) {
    case resp {
      response.Response(body: Websocket(selector), ..)
      | response.Response(body: ServerSentEvents(selector), ..) -> {
        let _resp = process.selector_receive_forever(selector)
        Error(Ok(Nil))
      }
      response.Response(body: body, ..) as resp -> {
        case body {
          Bytes(body) -> handle_bytes_tree_body(resp, body, conn, req, version)
          Chunked(body) -> handle_chunked_body(resp, body, conn, version)
          File(..) -> handle_file_body(resp, body, conn, version)
          _ -> panic as "This shouldn't ever happen 🤞"
        }
        |> result.replace_error(Ok(Nil))
        |> result.try(close_or_set_timer(_, conn, sender))
      }
    }
  })
}

fn log_and_error(
  error: Dynamic,
  socket: Socket,
  transport: Transport,
  req: Request(Connection),
  version: http.HttpVersion,
) -> Result(Nil, String) {
  logging.log(logging.Error, string.inspect(error))
  let resp =
    response.new(500)
    |> response.set_body(
      bytes_tree.from_bit_array(<<"Internal Server Error":utf8>>),
    )
    |> response.prepend_header("content-length", "21")
    |> http.add_default_headers(req.method == ghttp.Head)

  let resp = case version {
    http.Http1 -> http.connection_close(resp)
    _ -> http.maybe_keep_alive(resp)
  }

  let _ =
    resp
    |> encoder.to_bytes_tree(http.version_to_string(version))
    |> transport.send(transport, socket, _)

  let _ = transport.close(transport, socket)
  Error(string.inspect(error))
}

fn close_or_set_timer(
  resp: response.Response(BytesTree),
  conn: Connection,
  sender: Subject(handler.Message(user_message)),
) -> Result(State, Result(Nil, String)) {
  // If the handler explicitly says to close the connection, we should
  // probably listen to them
  case response.get_header(resp, "connection") {
    Ok("close") -> {
      let _ = transport.close(conn.transport, conn.socket)
      Error(Ok(Nil))
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
  body: Yielder(BytesTree),
  conn: Connection,
  version: http.HttpVersion,
) -> Result(response.Response(BytesTree), SocketReason) {
  let headers = [#("transfer-encoding", "chunked"), ..resp.headers]
  let initial_payload =
    encoder.response_builder(
      resp.status,
      headers,
      http.version_to_string(version),
    )

  transport.send(conn.transport, conn.socket, initial_payload)
  |> result.try(fn(_ok) {
    body
    |> yielder.append(yielder.from_list([bytes_tree.new()]))
    |> yielder.try_fold(Nil, fn(_prev, chunk) {
      let size = bytes_tree.byte_size(chunk)
      let encoded =
        size
        |> int_to_hex
        |> bytes_tree.from_string
        |> bytes_tree.append_string("\r\n")
        |> bytes_tree.append_tree(chunk)
        |> bytes_tree.append_string("\r\n")

      transport.send(conn.transport, conn.socket, encoded)
    })
  })
  |> result.replace(
    resp
    |> response.set_header("tranfer-encoding", "chunked")
    |> response.set_body(bytes_tree.new()),
  )
}

fn handle_file_body(
  resp: response.Response(ResponseData),
  body: ResponseData,
  conn: Connection,
  http_version: http.HttpVersion,
) -> Result(response.Response(BytesTree), SocketReason) {
  let assert File(file_descriptor, offset, length) = body
  let resp =
    resp
    |> response.set_body(bytes_tree.new())
    |> http.add_date_header
    |> response.prepend_header("content-length", int.to_string(length - offset))

  let resp = case http_version {
    http.Http1 -> http.connection_close(resp)
    _ -> http.maybe_keep_alive(resp)
  }

  let return =
    resp
    |> fn(r: response.Response(BytesTree)) {
      encoder.response_builder(
        resp.status,
        r.headers,
        http.version_to_string(http_version),
      )
    }
    |> transport.send(conn.transport, conn.socket, _)
    |> result.try(fn(_) {
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
    |> result.replace(resp)

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

fn handle_bytes_tree_body(
  resp: response.Response(ResponseData),
  body: BytesTree,
  conn: Connection,
  req: Request(Connection),
  version: http.HttpVersion,
) -> Result(response.Response(BytesTree), SocketReason) {
  let resp =
    resp
    |> response.set_body(body)
    |> http.add_default_headers(req.method == ghttp.Head)

  let resp = case version {
    http.Http1 -> http.connection_close(resp)
    _ -> http.maybe_keep_alive(resp)
  }

  resp
  |> encoder.to_bytes_tree(http.version_to_string(version))
  |> transport.send(conn.transport, conn.socket, _)
  |> result.replace(resp)
}

/// Creates a standard HTTP handler service to pass to `mist.serve`
@external(erlang, "erlang", "integer_to_list")
fn integer_to_list(int int: Int, base base: Int) -> String

fn int_to_hex(int: Int) -> String {
  integer_to_list(int, 16)
}
