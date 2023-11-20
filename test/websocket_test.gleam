import gleam/bit_array
import gleam/option.{None}
import gleeunit/should
import mist/internal/websocket.{
  Complete, Continuation, Data, Incomplete, TextFrame,
}

pub fn it_should_combine_continuation_frames_test() {
  let one = <<"Hello":utf8>>
  let two = <<", ":utf8>>
  let three = <<"world!":utf8>>
  let messages = [
    Incomplete(Data(TextFrame(bit_array.byte_size(one), one))),
    Incomplete(Continuation(bit_array.byte_size(two), two)),
    Complete(Continuation(bit_array.byte_size(three), three)),
  ]

  let combined = <<"Hello, world!":utf8>>

  messages
  |> websocket.aggregate_frames(None, [])
  |> should.equal(Ok([Data(TextFrame(bit_array.byte_size(combined), combined))]))
}
