import gleam/erlang/process
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import glisten.{type Loop, Packet}
import mist/internal/http.{
  type Connection, type DecodeError, type Handler, Connection, DiscardPacket,
  Initial,
}
import mist/internal/http/handler as http_handler
import mist/internal/http2/handler as http2_handler
import mist/internal/logger

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

pub type State {
  Http1(state: http_handler.State)
  Http2(state: http2_handler.State)
}

pub fn new_state() -> State {
  Http1(http_handler.initial_state())
}

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

    case state {
      Http1(state) -> {
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
              logger.error(err)
              let _ = conn.transport.close(conn.socket)
              process.Abnormal("Received invalid request")
            }
          }
        })
        |> result.then(fn(req) {
          case req {
            http.Http1Request(req) ->
              http_handler.call(req, handler, conn, sender)
              |> result.map(Http1)
            http.Upgrade(data) ->
              http2_handler.upgrade(data, conn)
              |> result.map(Http2)
          }
        })
      }
      Http2(state) ->
        http2_handler.call(state, msg, conn, handler)
        |> result.map(Http2)
    }
    |> result.map(actor.continue)
    |> result.map_error(actor.Stop)
    |> result.unwrap_both
  }
}
