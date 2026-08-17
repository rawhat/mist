import gleam/bit_array
import gleam/option.{None}
import gramps/websocket.{Complete, Continuation, Data, Incomplete, TextFrame}
import mist/internal/websocket as mist_websocket

pub fn it_should_combine_continuation_frames_test() {
  let one = <<"Hello":utf8>>
  let two = <<", ":utf8>>
  let three = <<"world!":utf8>>
  let messages = [
    Incomplete(Data(TextFrame(one))),
    Incomplete(Continuation(bit_array.byte_size(two), two)),
    Complete(Continuation(bit_array.byte_size(three), three)),
  ]

  let combined = <<"Hello, world!":utf8>>

  assert websocket.aggregate_frames(messages, None, [])
    == Ok([Data(TextFrame(combined))])
}

pub fn rejects_oversized_declared_payload_before_body_arrives_test() {
  let header_and_mask = <<1:1, 0:3, 1:4, 1:1, 126:7, 2048:16, 0:32>>

  assert mist_websocket.frames_within_limit(header_and_mask, 1024) == False
}

pub fn rejects_oversized_fragmented_message_test() {
  let fragments = <<
    0:1,
    0:3,
    1:4,
    0:1,
    20:7,
    0:size(160),
    1:1,
    0:3,
    0:4,
    0:1,
    20:7,
    0:size(160),
  >>

  assert mist_websocket.frames_within_limit(fragments, 32) == False
}
