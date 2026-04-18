import gleam/bytes_tree
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/response
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/result
import glisten.{type Loop, Packet, User}
import glisten/transport
import logging
import mist/internal/encoder
import mist/internal/http.{
  type DecodeError, type Handler, Bytes, Chunked, Connection, DiscardPacket,
  File, Initial, ServerSentEvents, Websocket,
}
import mist/internal/http/handler as http_handler
import mist/internal/http2
import mist/internal/http2/handler as http2_handler
import mist/internal/http2/stream.{type SendMessage, Send}

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

pub type State {
  Http1(state: http_handler.State, self: Subject(SendMessage))
  Http2(state: http2_handler.State)
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

pub fn with_func(
  handler: Handler,
  factory_name: process.Name(
    factory.Message(
      fn() -> Result(actor.Started(process.Pid), actor.StartError),
      process.Pid,
    ),
  ),
) -> Loop(State, SendMessage) {
  fn(state: State, msg, conn: glisten.Connection(SendMessage)) {
    let sender = conn.subject
    let conn =
      Connection(
        body: Initial(<<>>),
        socket: conn.socket,
        transport: conn.transport,
        factory_name:,
      )

    let result = case msg, state {
      User(Send(..)), Http1(..) -> {
        Error(Error("Attempted to send HTTP/2 response without upgrade"))
      }
      User(Send(id, resp)), Http2(state) -> {
        case resp.body {
          Bytes(bytes) -> {
            resp
            |> response.set_body(bytes)
            |> http2.send_bytes_tree(conn, state.send_hpack_context, id)
          }
          File(..) -> Error("File sending unsupported over HTTP/2")
          // TODO:  properly error in some fashion for these
          Websocket -> Error("WebSocket unsupported for HTTP/2")
          Chunked -> Error("Chunked encoding not supported for HTTP/2")
          ServerSentEvents -> Error("Server-Sent Events unsupported for HTTP/2")
        }
        |> result.map(fn(context) {
          Http2(http2_handler.send_hpack_context(state, context))
        })
        |> result.map_error(fn(err) {
          logging.log(logging.Debug, "Error sending HTTP/2 data: " <> err)
          Error(err)
        })
      }
      Packet(msg), Http1(state, self) -> {
        let _ = case state.idle_timer {
          Some(t) -> process.cancel_timer(t)
          _ -> process.TimerNotFound
        }
        msg
        |> http.parse_request(conn)
        |> result.map_error(fn(err) {
          case err {
            DiscardPacket -> Ok(Nil)
            http.MalformedRequest -> {
              let msg = "Received malformed HTTP request"
              logging.log(logging.Warning, msg)
              Error(msg)
            }
            http.InvalidMethod -> {
              let msg = "Received invalid HTTP method"
              logging.log(logging.Warning, msg)
              Error(msg)
            }
            http.InvalidPath -> {
              let msg = "Received invalid HTTP path"
              logging.log(logging.Warning, msg)
              Error(msg)
            }
            http.UnknownHeader -> {
              let msg = "Received unknown HTTP header"
              logging.log(logging.Warning, msg)
              Error(msg)
            }
            http.UnknownMethod -> {
              let msg = "Received unknown HTTP method"
              logging.log(logging.Warning, msg)
              Error(msg)
            }
            http.InvalidBody -> {
              let msg = "Received invalid HTTP body"
              logging.log(logging.Warning, msg)
              Error(msg)
            }
            http.NoHostHeader -> {
              let msg = "Missing HTTP `host` header"
              logging.log(logging.Warning, msg)
              let _ =
                response.new(400)
                |> response.prepend_header("connection", "close")
                |> response.set_body(bytes_tree.new())
                |> encoder.to_bytes_tree("1.1")
                |> transport.send(conn.transport, conn.socket, _)
              Ok(Nil)
            }
            http.InvalidHttpVersion -> {
              let msg = "Received invalid HTTP version"
              logging.log(logging.Warning, msg)
              Error(msg)
            }
          }
        })
        |> result.try(fn(req) {
          case req {
            http.Http1Request(req, version) ->
              http_handler.call(req, handler, sender, version)
              |> result.map(fn(new_state) {
                Http1(state: new_state, self: self)
              })
            http.Upgrade(data) ->
              http2_handler.upgrade(data, conn, self)
              |> result.map(Http2)
              |> result.map_error(Error)
          }
        })
      }
      Packet(msg), Http2(state) -> {
        state
        |> http2_handler.append_data(msg)
        |> http2_handler.call(conn, handler)
        |> result.map(Http2)
      }
    }

    case result {
      Ok(value) -> glisten.continue(value)
      Error(Ok(_nil)) -> glisten.stop()
      Error(Error(reason)) -> glisten.stop_abnormal(reason)
    }
  }
}
