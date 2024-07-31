import gleam/erlang/process.{type Selector, type Subject}
import gleam/function
import gleam/http/response
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import glisten.{type Loop, Packet, User}
import glisten/transport
import logging
import mist/internal/http.{
  type Connection, type DecodeError, type Handler, Bytes, Chunked, Connection,
  DiscardPacket, File, Initial, ServerSentEvents, Websocket,
}
import mist/internal/http/handler as http_handler
import mist/internal/http2
import mist/internal/http2/handler.{type Message, Send} as http2_handler

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

pub type State {
  Http1(state: http_handler.State, self: Subject(Message))
  Http2(state: http2_handler.State)
}

pub fn new_state(subj: Subject(Message)) -> State {
  Http1(http_handler.initial_state(), subj)
}

pub fn init(_conn) -> #(State, Option(Selector(Message))) {
  let subj = process.new_subject()
  let selector =
    process.new_selector()
    |> process.selecting(subj, function.identity)

  #(new_state(subj), Some(selector))
}

pub fn with_func(handler: Handler) -> Loop(Message, State) {
  fn(msg, state: State, conn: glisten.Connection(Message)) {
    let sender = conn.subject
    let conn =
      Connection(
        body: Initial(<<>>),
        socket: conn.socket,
        transport: conn.transport,
      )

    case msg, state {
      User(Send(..)), Http1(..) -> {
        Error(process.Abnormal(
          "Attempted to send HTTP/2 response without upgrade",
        ))
      }
      User(Send(id, resp)), Http2(state) -> {
        case resp.body {
          Bytes(bytes) -> {
            resp
            |> response.set_body(bytes)
            |> http2.send_bytes_builder(conn, state.send_hpack_context, id)
          }
          File(..) ->
            Error(process.Abnormal("File sending unsupported over HTTP/2"))
          // TODO:  properly error in some fashion for these
          Websocket(_selector) ->
            Error(process.Abnormal("WebSocket unsupported for HTTP/2"))
          Chunked(_iterator) ->
            Error(process.Abnormal("Chunked encoding not supported for HTTP/2"))
          ServerSentEvents(_selector) ->
            Error(process.Abnormal("Server-Sent Events unsupported for HTTP/2"))
        }
        |> result.map(fn(context) {
          Http2(http2_handler.send_hpack_context(state, context))
        })
        |> result.map_error(fn(err) {
          logging.log(
            logging.Debug,
            "Error sending HTTP/2 data: " <> string.inspect(err),
          )
          err
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
            DiscardPacket -> process.Normal
            _ -> {
              logging.log(logging.Error, string.inspect(err))
              let _ = transport.close(conn.transport, conn.socket)
              process.Abnormal("Received invalid request")
            }
          }
        })
        |> result.then(fn(req) {
          case req {
            http.Http1Request(req, version) ->
              http_handler.call(req, handler, conn, sender, version)
              |> result.map(fn(new_state) {
                Http1(state: new_state, self: self)
              })
            http.Upgrade(data) ->
              http2_handler.upgrade(data, conn, self)
              |> result.map(Http2)
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
    |> result.map(actor.continue)
    |> result.map_error(actor.Stop)
    |> result.unwrap_both
  }
}
