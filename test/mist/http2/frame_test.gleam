import gleam/option.{None}
import gleeunit/should
import mist/internal/http2/frame.{Complete, Data, Header, stream_identifier}

pub fn it_should_encode_data_frame_test() {
  Data(identifier: stream_identifier(123), end_stream: False, data: <<1, 2, 3>>)
  |> frame.encode
  |> should.equal(<<0, 0, 3, 0, 0, 0, 0, 0, 123, 1, 2, 3>>)
}

pub fn it_should_encode_headers_frame_test() {
  Header(
    identifier: stream_identifier(123),
    end_stream: False,
    data: Complete(<<1, 2, 3>>),
    priority: None,
  )
  |> frame.encode
  |> should.equal(<<0, 0, 3, 1, 4, 0, 0, 0, 123, 1, 2, 3>>)
}
