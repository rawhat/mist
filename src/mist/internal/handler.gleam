import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import glisten.{type Loop, Packet, User}
import glisten/transport
import logging
import mist/internal/encoder
import mist/internal/http.{
  type Connection, type DecodeError, type Handler, type ResponseData, Bytes, Chunked, Connection,
  DiscardPacket, File, Initial, ServerSentEvents, Websocket,
}
import glisten/internal/handler
import mist/internal/http/handler as http_handler
import mist/internal/http2
import mist/internal/http2/frame
import mist/internal/http2/handler as http2_handler
import mist/internal/http2/stream.{type SendMessage, Send}

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

pub type State {
  Http1(state: http_handler.State, self: Subject(SendMessage))
  Http2(state: http2_handler.State)
  AwaitingH2cPreface(
    self: Subject(SendMessage),
    settings: Option(http2.Http2Settings),
    buffer: BitArray,
    original_request: Option(Request(Connection)),
  )
}

pub type Config {
  Config(http2_settings: Option(http2.Http2Settings))
}

pub fn new_state(subj: Subject(SendMessage)) -> State {
  Http1(http_handler.initial_state(), subj)
}

pub fn init(_conn) -> #(State, Option(Selector(SendMessage))) {
  let subj = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(subj)

  #(new_state(subj), Some(selector))
}

pub fn init_with_config(
  _config: Option(http2.Http2Settings),
) -> fn(glisten.Connection(SendMessage)) ->
  #(State, Option(Selector(SendMessage))) {
  fn(_conn) {
    let subj = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(subj)

    #(new_state(subj), Some(selector))
  }
}

pub fn with_func(handler: Handler) -> Loop(State, SendMessage) {
  with_func_and_config(None, handler)
}

fn handle_http2_send_message(
  id: frame.StreamIdentifier(frame.Frame),
  resp: response.Response(ResponseData),
  state: http2_handler.State,
  conn: Connection,
) -> Result(State, Result(Nil, String)) {
  case resp.body {
    Bytes(bytes) -> {
      resp
      |> response.set_body(bytes)
      |> http2.send_bytes_tree(conn, state.send_hpack_context, id)
    }
    File(..) -> Error("File sending unsupported over HTTP/2")
    Websocket(_selector) -> Error("WebSocket unsupported for HTTP/2")
    Chunked(_iterator) -> Error("Chunked encoding not supported for HTTP/2")
    ServerSentEvents(_selector) -> Error("Server-Sent Events unsupported for HTTP/2")
  }
  |> result.map(fn(context) {
    Http2(http2_handler.send_hpack_context(state, context))
  })
  |> result.map_error(fn(err) {
    logging.log(
      logging.Debug,
      "Error sending HTTP/2 data: " <> string.inspect(err),
    )
    Error(string.inspect(err))
  })
}

fn handle_http1_packet(
  msg: BitArray,
  state: http_handler.State,
  self: Subject(SendMessage),
  conn: Connection,
  sender: Subject(handler.Message(SendMessage)),
  handler: Handler,
  http2_settings: Option(http2.Http2Settings),
) -> Result(State, Result(Nil, String)) {
  let _ = case state.idle_timer {
    Some(t) -> process.cancel_timer(t)
    _ -> process.TimerNotFound
  }
  
  use req <- result.try(
    msg
    |> http.parse_request(conn)
    |> result.map_error(fn(err) {
      case err {
        DiscardPacket -> Ok(Nil)
        _ -> {
          logging.log(logging.Error, string.inspect(err))
          let _ = transport.close(conn.transport, conn.socket)
          Error("Received invalid request")
        }
      }
    })
  )
  
  case req {
    http.Http1Request(req, version) ->
      http_handler.call(req, handler, conn, sender, version)
      |> result.map(fn(new_state) {
        Http1(state: new_state, self: self)
      })
    http.Upgrade(data) ->
      http2_handler.upgrade_with_settings(data, conn, self, http2_settings)
      |> result.map(Http2)
      |> result.map_error(Error)
    http.H2cUpgrade(req, _settings) ->
      handle_h2c_upgrade_request(req, conn, self, http2_settings)
  }
}

fn handle_h2c_upgrade_request(
  req: request.Request(Connection),
  conn: Connection,
  self: Subject(SendMessage),
  http2_settings: Option(http2.Http2Settings),
) -> Result(State, Result(Nil, String)) {
  let resp_101 =
    response.new(101)
    |> response.set_body(bytes_tree.new())
    |> response.set_header("connection", "Upgrade")
    |> response.set_header("upgrade", "h2c")

  let _ =
    resp_101
    |> encoder.to_bytes_tree("1.1")
    |> transport.send(conn.transport, conn.socket, _)
  let _ = http.set_socket_packet_mode(conn.transport, conn.socket, http.RawPacket)
  let _ = http.set_socket_active(conn.transport, conn.socket)

  Ok(AwaitingH2cPreface(self, http2_settings, <<>>, Some(req)))
}

fn process_original_http2_request(
  req: request.Request(Connection),
  handler: Handler,
  state: http2_handler.State,
  conn: Connection,
) -> Result(State, Result(Nil, String)) {
  let resp = handler(req)
  case resp.body {
    Bytes(bytes_tree) -> {
      let http2_resp = response.Response(..resp, body: bytes_tree)
      case http2.send_bytes_tree(
        http2_resp,
        conn,
        state.send_hpack_context,
        frame.stream_identifier(1),
      ) {
        Ok(new_context) -> {
          let updated_state = http2_handler.send_hpack_context(state, new_context)
          Ok(Http2(updated_state))
        }
        Error(_err) -> Ok(Http2(state))  // Continue even if response fails
      }
    }
    _ -> Ok(Http2(state))
  }
}

fn validate_h2c_preface(accumulated: BitArray) -> Bool {
  let preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>
  let preface_size = bit_array.byte_size(preface)
  let accumulated_size = bit_array.byte_size(accumulated)
  
  case accumulated_size >= preface_size {
    True -> False  // Invalid if we have enough bytes but no match
    False -> {
      case accumulated {
        <<"PRI":utf8, _:bits>> -> True
        <<"PR":utf8, _:bits>> -> True
        <<"P":utf8, _:bits>> -> True
        <<>> -> True
        _ -> {
          let assert <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>> = preface
          bit_array.slice(preface, 0, accumulated_size)
          |> result.map(fn(prefix) {
            bit_array.compare(accumulated, prefix) == order.Eq
          })
          |> result.unwrap(False)
        }
      }
    }
  }
}

fn handle_h2c_preface(
  accumulated: BitArray,
  self: Subject(SendMessage),
  http2_settings: Option(http2.Http2Settings),
  original_request: Option(request.Request(Connection)),
  conn: Connection,
  handler: Handler,
) -> Result(State, Result(Nil, String)) {
  case accumulated {
    <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8, rest:bits>> -> {
      let _ = http.set_socket_active_continuous(conn.transport, conn.socket)
      case http2_handler.upgrade_with_settings(rest, conn, self, http2_settings) {
        Ok(state) -> {
          case original_request {
            Some(req) -> 
              process_original_http2_request(req, handler, state, conn)
            None -> Ok(Http2(state))
          }
        }
        Error(err) -> Error(Error(err))
      }
    }
    _ -> {
      case validate_h2c_preface(accumulated) {
        True -> {
          let _ = http.set_socket_active(conn.transport, conn.socket)
          Ok(AwaitingH2cPreface(self, http2_settings, accumulated, original_request))
        }
        False -> {
          logging.log(
            logging.Error,
            "Invalid HTTP/2 preface: " <> string.inspect(accumulated),
          )
          Error(Error("Invalid HTTP/2 preface"))
        }
      }
    }
  }
}

pub fn with_func_and_config(
  http2_settings: Option(http2.Http2Settings),
  handler: Handler,
) -> Loop(State, SendMessage) {
  fn(state: State, msg, conn: glisten.Connection(SendMessage)) {
    let sender = conn.subject
    let conn =
      Connection(
        body: Initial(<<>>),
        socket: conn.socket,
        transport: conn.transport,
      )

    case msg, state {
      User(Send(..)), Http1(..) -> {
        Error(Error("Attempted to send HTTP/2 response without upgrade"))
      }
      User(Send(id, resp)), Http2(state) -> {
        handle_http2_send_message(id, resp, state, conn)
      }
      Packet(msg), Http1(state, self) -> {
        handle_http1_packet(msg, state, self, conn, sender, handler, http2_settings)
      }
      Packet(msg), Http2(state) -> {
        state
        |> http2_handler.append_data(msg)
        |> http2_handler.call(conn, handler)
        |> result.map(Http2)
      }
      Packet(msg),
        AwaitingH2cPreface(self, http2_settings, buffer, original_request)
      -> {
        let accumulated = bit_array.append(buffer, msg)
        handle_h2c_preface(accumulated, self, http2_settings, original_request, conn, handler)
      }
      User(_), AwaitingH2cPreface(..) -> {
        // Ignore user messages while waiting for preface
        Ok(state)
      }
    }
    |> result.map(glisten.continue)
    |> result.map_error(fn(err) {
      case err {
        Ok(_nil) -> glisten.stop()
        Error(reason) -> glisten.stop_abnormal(reason)
      }
    })
    |> result.unwrap_both
  }
}
