import gleam/bit_builder.{BitBuilder}
import gleam/erlang/process.{Subject}
import gleam/http
import gleam/http/request
import gleam/http/response.{Response}
import gleam/list
import gleam/set
import gleeunit/should
import glisten/acceptor.{AcceptorMessage}
import glisten/tcp
import mist/handler.{Handler}
import mist/http.{Chunked} as mhttp
import gleam/bit_string
import gleam/string
import gleam/iterator

pub fn echo_handler() -> Handler {
  fn(req: request.Request(BitString)) {
    let headers =
      list.filter(
        req.headers,
        fn(p) {
          case p {
            #("transfer-encoding", "chunked") -> False
            _ -> True
          }
        },
      )
    Response(
      status: 200,
      headers: headers,
      body: bit_builder.from_bit_string(req.body),
    )
  }
}

pub fn chunked_echo_server(
  port: Int,
  chunk_size: Int,
) -> Subject(AcceptorMessage) {
  let assert Ok(listener) = tcp.listen(port, [])
  let pool =
    fn(req: request.Request(mhttp.Body)) {
      let assert Ok(req) = mhttp.read_body(req)
      let assert Ok(body) = bit_string.to_string(req.body)
      let chunks =
        body
        |> string.to_graphemes
        |> iterator.from_list
        |> iterator.sized_chunk(chunk_size)
        |> iterator.map(fn(chars) {
          chars
          |> string.join("")
          |> bit_builder.from_string
        })
      response.new(200)
      |> response.set_body(Chunked(chunks))
      |> handler.Response
    }
    |> handler.with_func
    |> acceptor.new_pool_with_data(handler.new_state())
    |> fn(func) { func(listener) }
  let assert Ok(sender) = acceptor.start(pool)
  sender
}

pub fn open_server(port: Int, handler: Handler) -> Subject(AcceptorMessage) {
  let assert Ok(listener) = tcp.listen(port, [])
  let pool =
    handler
    |> handler.with(4_000_000)
    |> acceptor.new_pool_with_data(handler.new_state())
    |> fn(func) { func(listener) }
  let assert Ok(sender) = acceptor.start(pool)
  sender
}

fn compare_bitstring_body(actual: BitString, expected: BitBuilder) {
  actual
  |> bit_builder.from_bit_string
  |> should.equal(expected)
}

fn compare_string_body(actual: String, expected: BitBuilder) {
  actual
  |> bit_builder.from_string
  |> should.equal(expected)
}

fn compare_headers_and_status(actual: Response(a), expected: Response(b)) {
  should.equal(actual.status, expected.status)

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

pub fn string_response_should_equal(
  actual: Response(String),
  expected: Response(BitBuilder),
) {
  compare_headers_and_status(actual, expected)
  compare_string_body(actual.body, expected.body)
}

pub fn bitstring_response_should_equal(
  actual: Response(BitString),
  expected: Response(BitBuilder),
) {
  compare_headers_and_status(actual, expected)
  compare_bitstring_body(actual.body, expected.body)
}

pub fn make_request(path: String, body: body) -> request.Request(body) {
  request.new()
  |> request.set_host("localhost:8888")
  |> request.set_method(http.Post)
  |> request.set_path(path)
  |> request.set_body(body)
  |> request.set_scheme(http.Http)
}

type IoFormat {
  User
}

external fn io_fwrite(format: IoFormat, output_format: String, data: any) -> Nil =
  "io" "fwrite"

pub fn io_fwrite_user(data: anything) {
  io_fwrite(User, "~tp\n", [data])
}
