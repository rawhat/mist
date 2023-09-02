import gleam/erlang/process.{Subject}
import gleam/otp/actor
import mist/internal/http2/frame.{StreamIdentifier}

pub type Message {
  PartialHeaders(data: BitString)
  CompleteHeaders(data: BitString)
  PartialBody(data: BitString)
  CompleteBody(data: BitString)
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
) -> Result(Subject(Message), actor.StartError) {
  actor.start(
    State(
      headers: <<>>,
      body: <<>>,
      identifier: identifier,
      window_size: window_size,
    ),
    fn(msg, state) { todo },
  )
}
