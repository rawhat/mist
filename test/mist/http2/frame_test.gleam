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

pub fn it_should_encode_data_frame_with_end_of_stream_test() {
  Data(identifier: stream_identifier(123), end_stream: True, data: <<1, 2, 3>>)
  |> frame.encode
  |> should.equal(<<0, 0, 3, 0, 1, 0, 0, 0, 123, 1, 2, 3>>)
}

pub fn it_should_encode_headers_frame_with_end_of_stream_test() {
  Header(
    identifier: stream_identifier(123),
    end_stream: True,
    data: Complete(<<1, 2, 3>>),
    priority: None,
  )
  |> frame.encode
  |> should.equal(<<0, 0, 3, 1, 5, 0, 0, 0, 123, 1, 2, 3>>)
}

pub fn it_should_return_error_when_incomplete_test() {
  let data = <<0, 0, 0, 4>>
  frame.decode(data)
  |> should.equal(Error(frame.ProtocolError))
}

pub fn it_should_decode_data_frame_test() {
  let data = <<0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3>>
  frame.decode(data)
  |> should.equal(
    Ok(
      #(
        frame.Data(
          identifier: stream_identifier(1),
          data: <<>>,
          end_stream: False,
        ),
        <<1, 2, 3>>,
      ),
    ),
  )
}

pub fn it_should_decode_full_header_message_test() {
  let msg = <<
    0, 0, 38, 1, 37, 0, 0, 0, 13, 0, 0, 0, 11, 15, 130, 132, 135, 65, 138, 160,
    228, 29, 19, 157, 9, 184, 17, 50, 215, 83, 3, 42, 47, 42, 144, 122, 138, 170,
    105, 210, 154, 196, 192, 87, 109, 229, 193, 0, 0, 0, 4, 1, 0, 0, 0, 0,
  >>

  let assert Ok(#(frame.Header(data, ..), rest)) = frame.decode(msg)

  data
  |> should.equal(
    frame.Complete(<<
      130, 132, 135, 65, 138, 160, 228, 29, 19, 157, 9, 184, 17, 50, 215, 83, 3,
      42, 47, 42, 144, 122, 138, 170, 105, 210, 154, 196, 192, 87, 109, 229, 193,
    >>),
  )

  rest
  |> should.equal(<<0, 0, 0, 4, 1, 0, 0, 0, 0>>)
}
