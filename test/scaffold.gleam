import gleam/bit_builder.{BitBuilder}
import gleam/http/request
import gleam/http/response.{Response}
import gleam/option.{None}
import gleam/otp/process.{Sender}
import gleam/set
import gleeunit/should
import glisten/tcp
import mist/http as mhttp

pub fn echo_handler() -> mhttp.Handler {
  fn(req: request.Request(BitString)) {
    Response(
      status: 200,
      headers: req.headers,
      body: bit_builder.from_bit_string(req.body),
    )
  }
}

pub fn open_server(port: Int, handler: mhttp.Handler) -> Sender(tcp.Acceptor) {
  assert Ok(listener) = tcp.listen(port, [])
  assert Ok(sender) = tcp.start_acceptor(listener, None, mhttp.handler(handler))
  sender
}

pub fn response_should_equal(
  actual: Response(String),
  expected: Response(BitBuilder),
) {
  should.equal(actual.status, expected.status)

  actual.body
  |> bit_builder.from_string
  |> should.equal(expected.body)

  let expected_headers = set.from_list(expected.headers)
  let actual_headers = set.from_list(actual.headers)

  let missing_headers =
    set.filter(
      expected_headers,
      fn(header) { set.contains(actual_headers, header) == False },
    )
  let extra_headers =
    set.filter(
      actual_headers,
      fn(header) { set.contains(expected_headers, header) == False },
    )

  should.equal(missing_headers, extra_headers)
}

type IoFormat {
  User
}

external fn io_fwrite(format: IoFormat, output_format: String, data: any) -> Nil =
  "io" "fwrite"

pub fn io_fwrite_user(data: anything) {
  io_fwrite(User, "~tp\n", [data])
}
