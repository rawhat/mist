import gleam/bit_builder.{BitBuilder}
import gleam/dynamic
import gleam/erlang.{Errored, Exited, Thrown, rescue}
import gleam/erlang/process.{ProcessDown, Selector}
import gleam/http/request.{Request}
import gleam/http/response
import gleam/int
import gleam/iterator.{Iterator}
import gleam/option.{None, Option, Some}
import gleam/otp/actor
import gleam/result
import glisten/handler.{Close, HandlerMessage, LoopFn, LoopState}
import glisten/socket.{Socket}
import glisten/socket/transport.{Transport}
import mist/internal/encoder
import mist/internal/file
import mist/internal/http.{Connection, DecodeError, DiscardPacket}
import mist/internal/logger

pub type ResponseData {
  Websocket(Selector(ProcessDown))
  Bytes(BitBuilder)
  Chunked(Iterator(BitBuilder))
  File(descriptor: file.FileDescriptor, offset: Int, length: Int)
}

pub type Handler =
  fn(request.Request(BitString)) -> response.Response(BitBuilder)

pub type HandlerFunc =
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
pub fn with_func(handler: HandlerFunc) -> LoopFn(HandlerMessage, State) {
  handler.func(fn(msg, socket_state: LoopState(State)) {
    let LoopState(
      socket: socket,
      transport: transport,
      data: state,
      client_ip: client_ip,
      ..,
    ) = socket_state
    {
      let _ = case state.idle_timer {
        Some(t) -> process.cancel_timer(t)
        _ -> process.TimerNotFound
      }
      msg
      |> http.parse_request(socket, transport, client_ip)
      |> result.map_error(fn(err) {
        case err {
          DiscardPacket -> Nil
          _ -> {
            logger.error(err)
            let _ = transport.close(socket)
            Nil
          }
        }
      })
      |> result.replace_error(stop_normal)
      |> result.then(fn(req) {
        rescue(fn() { handler(req) })
        |> result.map(fn(resp) { #(req, resp) })
        |> result.map_error(log_and_error(
          _,
          socket_state.socket,
          socket_state.transport,
        ))
      })
      |> result.map(fn(req_resp) {
        let #(_req, response) = req_resp
        case response {
          response.Response(body: Bytes(body), ..) as resp ->
            handle_bit_builder_body(resp, body, socket_state)
          response.Response(body: Chunked(body), ..) as resp ->
            handle_chunked_body(resp, body, socket_state)
          response.Response(body: File(..), ..) as resp ->
            handle_file_body(resp, socket_state)
          response.Response(body: Websocket(selector), ..) -> {
            let _resp = process.select_forever(selector)
            actor.Stop(process.Normal)
          }
        }
      })
    }
    |> result.unwrap_both
  })
}

fn log_and_error(
  error: erlang.Crash,
  socket: Socket,
  transport: Transport,
) -> actor.Next(HandlerMessage, LoopState(State)) {
  case error {
    Exited(msg) | Thrown(msg) | Errored(msg) -> {
      logger.error(error)
      response.new(500)
      |> response.set_body(bit_builder.from_bit_string(<<
        "Internal Server Error":utf8,
      >>))
      |> response.prepend_header("content-length", "21")
      |> http.add_default_headers
      |> encoder.to_bit_builder
      |> transport.send(socket, _)
      let _ = transport.close(socket)
      actor.Stop(process.Abnormal(dynamic.unsafe_coerce(msg)))
    }
  }
}

fn handle_bit_builder_body(
  resp: response.Response(ResponseData),
  body: BitBuilder,
  state: LoopState(State),
) -> actor.Next(HandlerMessage, LoopState(State)) {
  resp
  |> response.set_body(body)
  |> http.add_default_headers
  |> encoder.to_bit_builder
  |> state.transport.send(state.socket, _)
  |> result.map(fn(_sent) {
    // If the handler explicitly says to close the connection, we should
    // probably listen to them
    case response.get_header(resp, "connection") {
      Ok("close") -> {
        let _ = state.transport.close(state.socket)
        stop_normal
      }
      _ -> {
        // TODO:  this should be a configuration
        let timer = process.send_after(state.sender, 10_000, Close)
        actor.continue(LoopState(..state, data: State(idle_timer: Some(timer))))
      }
    }
  })
  |> result.replace_error(stop_normal)
  |> result.unwrap_both
}

fn int_to_hex(int: Int) -> String {
  integer_to_list(int, 16)
}

fn handle_chunked_body(
  resp: response.Response(ResponseData),
  body: Iterator(BitBuilder),
  state: LoopState(State),
) -> actor.Next(HandlerMessage, LoopState(State)) {
  let headers = [#("transfer-encoding", "chunked"), ..resp.headers]
  let initial_payload = encoder.response_builder(resp.status, headers)

  state.transport.send(state.socket, initial_payload)
  |> result.then(fn(_ok) {
    body
    |> iterator.append(iterator.from_list([bit_builder.new()]))
    |> iterator.try_fold(
      Nil,
      fn(_prev, chunk) {
        let size = bit_builder.byte_size(chunk)
        let encoded =
          size
          |> int_to_hex
          |> bit_builder.from_string
          |> bit_builder.append_string("\r\n")
          |> bit_builder.append_builder(chunk)
          |> bit_builder.append_string("\r\n")

        state.transport.send(state.socket, encoded)
      },
    )
  })
  |> result.replace(actor.continue(state))
  |> result.unwrap(stop_normal)
}

fn handle_file_body(
  resp: response.Response(ResponseData),
  state: LoopState(State),
) -> actor.Next(HandlerMessage, LoopState(State)) {
  let assert File(file_descriptor, offset, length) = resp.body
  resp
  |> response.prepend_header("content-length", int.to_string(length - offset))
  |> response.set_body(bit_builder.new())
  |> fn(r: response.Response(BitBuilder)) {
    encoder.response_builder(resp.status, r.headers)
  }
  |> state.transport.send(state.socket, _)
  |> result.replace_error(Nil)
  |> result.then(fn(_) {
    file.sendfile(file_descriptor, state.socket, offset, length, [])
    |> result.map_error(fn(err) { logger.error(#("Failed to send file", err)) })
    |> result.replace_error(Nil)
  })
  |> result.replace(actor.continue(state))
  // TODO:  not normal
  |> result.replace_error(stop_normal)
  |> result.unwrap_both
}

/// Creates a standard HTTP handler service to pass to `mist.serve`
pub fn with(
  handler: Handler,
  max_body_limit: Int,
) -> LoopFn(HandlerMessage, State) {
  let bad_request =
    response.new(400)
    |> response.set_body(bit_builder.new())
  with_func(fn(req) {
    case
      request.get_header(req, "content-length"),
      request.get_header(req, "transfer-encoding")
    {
      Ok("0"), _ | Error(Nil), Error(Nil) ->
        req
        |> request.set_body(<<>>)
        |> handler
      _, Ok("chunked") ->
        req
        |> http.read_body
        |> result.map(handler)
        |> result.unwrap(bad_request)
      Ok(size), _ ->
        size
        |> int.parse
        |> result.map(fn(size) {
          case size > max_body_limit {
            True ->
              response.new(413)
              |> response.set_body(bit_builder.new())
              |> response.prepend_header("connection", "close")
            False ->
              req
              |> http.read_body
              |> result.map(handler)
              |> result.unwrap(bad_request)
          }
        })
        |> result.unwrap(bad_request)
    }
    |> response.map(Bytes)
  })
}

@external(erlang, "erlang", "integer_to_list")
fn integer_to_list(int int: Int, base base: Int) -> String
