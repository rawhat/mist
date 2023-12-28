import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/otp/actor
import mist/internal/http2/frame.{type StreamIdentifier}
import mist/internal/http.{type Connection, type Handler, Connection, Initial}

pub type Message {
  HeaderChunk(data: BitArray)
  LastHeaderChunk(data: BitArray, end_of_stream: Bool)
  BodyChunk(data: BitArray)
  LastBodyChunk(data: BitArray)
}

pub type State(any) {
  State(
    headers: BitArray,
    body: BitArray,
    identifier: StreamIdentifier(any),
    window_size: Int,
  )
}

import gleam/io

pub fn new(
  identifier: StreamIdentifier(any),
  window_size: Int,
  handler: Handler,
  connection: Connection,
) -> Result(Subject(Message), actor.StartError) {
  actor.start(
    State(
      headers: <<>>,
      body: <<>>,
      identifier: identifier,
      window_size: window_size,
    ),
    fn(msg, state) {
      io.debug(#("our stream got a msg", msg, "with state", state))
      case msg {
        HeaderChunk(data) ->
          actor.continue(
            State(..state, headers: bit_array.append(state.headers, data)),
          )
        LastHeaderChunk(data, False) -> {
          let headers = bit_array.append(state.headers, data)
          actor.continue(State(..state, headers: headers))
        }
        LastHeaderChunk(_data, True) -> {
          let req =
            request.new()
            |> request.set_body(Connection(..connection, body: Initial(<<>>)))
          let _resp = handler(req)
          // TODO:  maybe send?
          actor.Stop(process.Normal)
        }
        BodyChunk(data) ->
          actor.continue(
            State(..state, body: bit_array.append(state.headers, data)),
          )
        LastBodyChunk(data) -> {
          let body = bit_array.append(state.body, data)
          let req =
            request.new()
            |> request.set_body(Connection(..connection, body: Initial(body)))
          let _resp = handler(req)
          // TODO:  maybe send?
          actor.Stop(process.Normal)
        }
      }
    },
  )
}
