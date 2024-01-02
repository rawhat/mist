import gleam/erlang/process.{type Selector, type Subject}
import gleam/function
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/result
import glisten.{type Loop, Packet}
import mist/internal/http.{
  type Connection, type DecodeError, type Handler, Connection, DiscardPacket,
  Initial,
}
import mist/internal/http/handler as http_handler
import mist/internal/http2/handler.{type Message} as http2_handler
import mist/internal/logger

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

pub fn init() -> #(State, Option(Selector(Message))) {
  let subj = process.new_subject()
  let selector =
    process.new_selector()
    |> process.selecting(subj, function.identity)

  #(new_state(subj), Some(selector))
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
      Http1(state, self) -> {
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
              |> result.map(fn(new_state) {
                Http1(state: new_state, self: self)
              })
            http.Upgrade(data) ->
              http2_handler.upgrade(data, conn, self)
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
