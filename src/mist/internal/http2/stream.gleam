import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/erlang/process.{Subject}
import gleam/http/request
import gleam/http/response
import gleam/otp/actor
import mist/internal/http2/frame.{StreamIdentifier}

pub type Message {
  HeaderChunk(data: BitString)
  LastHeaderChunk(data: BitString, end_of_stream: Bool)
  BodyChunk(data: BitString)
  LastBodyChunk(data: BitString)
}

pub type State(any) {
  State(
    headers: BitString,
    body: BitString,
    identifier: StreamIdentifier(any),
    window_size: Int,
  )
}

pub fn new(
  identifier: StreamIdentifier(any),
  window_size: Int,
  handler: fn(request.Request(BitString)) -> response.Response(BitBuilder),
  _sender: fn(BitString) -> Result(ok, err),
) -> Result(Subject(Message), actor.StartError) {
  actor.start(
    State(
      headers: <<>>,
      body: <<>>,
      identifier: identifier,
      window_size: window_size,
    ),
    fn(msg, state) {
      case msg {
        HeaderChunk(data) ->
          actor.continue(
            State(..state, headers: bit_string.append(state.headers, data)),
          )
        LastHeaderChunk(data, False) ->
          actor.continue(
            State(..state, headers: bit_string.append(state.headers, data)),
          )
        LastHeaderChunk(data, True) -> {
          let req =
            request.new()
            |> request.set_body(<<>>)
          let _resp = handler(req)
          // TODO:  maybe send?
          actor.Stop(process.Normal)
        }
        BodyChunk(data) ->
          actor.continue(
            State(..state, body: bit_string.append(state.headers, data)),
          )
        LastBodyChunk(data) -> {
          let req =
            request.new()
            |> request.set_body(<<>>)
          let _resp = handler(req)
          let _resp = handler(req)
          // TODO:  maybe send?
          actor.Stop(process.Normal)
        }
      }
    },
  )
}
