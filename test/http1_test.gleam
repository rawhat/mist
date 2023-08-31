import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/http
import gleam/http/request
import gleam/http/response.{Response}
import gleam/hackney
import gleam/string
import gleam/uri
import gleam/option.{Some}
import gleeunit/should
import scaffold.{
  bitstring_response_should_equal, echo_handler, make_request, open_server,
  string_response_should_equal,
}

pub type Fixture {
  Foreach
  Setup
}

pub type Instantiator {
  Spawn
  Timeout
  Inorder
  Inparallel
}

pub fn set_up_echo_server_test_() {
  #(
    Setup,
    fn() { open_server(8888, echo_handler()) },
    [
      it_echoes_with_data,
      it_supports_large_header_fields,
      it_supports_patch_requests,
      it_rejects_large_requests,
      it_supports_chunked_encoding,
      it_supports_query_parameters,
      it_handles_query_parameters_with_question_mark,
      it_doesnt_mangle_query,
      it_supports_expect_continue_header,
    ],
  )
}

fn get_default_response() -> Response(BitBuilder) {
  response.new(200)
  |> response.prepend_header("user-agent", "hackney/1.18.2")
  |> response.prepend_header("host", "localhost:8888")
  |> response.prepend_header("content-type", "application/octet-stream")
  |> response.prepend_header("content-length", "13")
  |> response.prepend_header("connection", "keep-alive")
  |> response.set_body(bit_builder.from_bit_string(<<"hello, world!":utf8>>))
}

pub fn it_echoes_with_data() {
  let req = make_request("/", "hello, world!")

  let assert Ok(resp) = hackney.send(req)

  string_response_should_equal(resp, get_default_response())
}

pub fn it_supports_large_header_fields() {
  let big_request =
    make_request("/", "")
    |> request.prepend_header(
      "user-agent",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:100.0) Gecko/20100101 Firefox/100.0",
    )
    |> request.prepend_header(
      "accept",
      "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    )
    |> request.prepend_header("accept-language", "en-GB,en;q=0.5")
    |> request.prepend_header("accept-encoding", "gzip, deflate, br")
    |> request.prepend_header("dnt", "1")
    |> request.prepend_header("connection", "keep-alive")
    |> request.prepend_header(
      "cookie",
      "csrftoken=redacted; firstVisit=redacted; sessionid=redacted; ph_GO532nkfIyRbVh8r-ts579S0ibtS4N7F8q1u7qy9FyY_posthog=%7B%22distinct_id%22%3A%22development-309%22%2C%22%24device_id%22%3A%2217f2233bb99e1f-0c5659974edb81-455a69-7e9000-17f2233bb9a8d6%22%2C%22%24user_id%22%3A%22development-309%22%2C%22%24initial_referrer%22%3A%22http%3A%2F%2Flocalhost%3A8000%2F%22%2C%22%24initial_referring_domain%22%3A%22localhost%3A8000%22%2C%22%24referrer%22%3A%22http%3A%2F%2Flocalhost%3A8000%2Fin-house-legal%2Fquery%2Fagreements%2F%22%2C%22%24referring_domain%22%3A%22localhost%3A8000%22%2C%22%24sesid%22%3A%5B1653655256592%2C%221810588be10b6a-070d87da3b86a88-402e2c34-4b9600-1810588be11e5a%22%5D%2C%22%24session_recording_enabled_server_side%22%3Afalse%2C%22%24active_feature_flags%22%3A%5B%5D%2C%22%24enabled_feature_flags%22%3A%7B%7D%7D; uid=SFMyNTY.MQ.3UIahins3fngCF2xLC2znGYe_xSbmG_bRdx0YSTwt_c; sessionid-3GDYO=redacted; CSRF-Token-3GDYO=tJoio2hbqKggK7fHZgFZyWVPnA7wySLf; CSRF-Token-CKIKR=Xc75SKFZS9qDDgLKD26rLYJtgtiH7Gja; sessionid-CKIKR=eikQox9V6M9sQwRnLHLj9HE5b2zRtopN; sessionid-NHOUY=wV9rHjEGqHzSpTfVrtMw3SkSUfV99YWq; CSRF-Token-NHOUY=ePu9N5NuRQSS6bwRfvrRTiSNdKjJV9Ro",
    )
    |> request.prepend_header("upgrade-insecure-requests", "")
    |> request.prepend_header("sec-fetch-dest", "1")
    |> request.prepend_header("sec-fetch-mode", "document")
    |> request.prepend_header("sec-fetch-site", "navigate")
    |> request.prepend_header("sec-fetch-user", "none")
    |> request.prepend_header("pragma", "no-cache")
    |> request.prepend_header("cache-control", "no-cache")

  let expected =
    Response(..get_default_response(), headers: big_request.headers)
    |> response.prepend_header("content-type", "application/octet-stream")
    |> response.prepend_header("content-length", "0")
    |> response.prepend_header("host", "localhost:8888")
    |> response.set_body(bit_builder.from_bit_string(<<>>))

  let assert Ok(resp) = hackney.send(big_request)

  string_response_should_equal(resp, expected)
}

pub fn it_supports_patch_requests() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Patch)

  let assert Ok(resp) = hackney.send(req)

  string_response_should_equal(resp, get_default_response())
}

pub fn it_rejects_large_requests() {
  let req =
    string.repeat("a", 4_000_001)
    |> make_request("/", _)

  let assert Ok(resp) = hackney.send(req)

  let expected =
    response.new(413)
    |> response.set_body(bit_builder.from_bit_string(<<>>))
    |> response.prepend_header("content-length", "0")
    |> response.prepend_header("connection", "close")

  string_response_should_equal(resp, expected)
}

@external(erlang, "hackney_ffi", "stream_request")
fn stream_request(
  method method: http.Method,
  path path: String,
  headers headers: List(#(String, String)),
  body body: BitString,
) -> Result(#(Int, List(#(String, String)), BitString), Nil)

pub fn it_supports_chunked_encoding() {
  let req =
    string.repeat("a", 10_000)
    |> bit_string.from_string
    |> make_request("/", _)
    |> request.set_method(http.Post)
    |> request.prepend_header("transfer-encoding", "chunked")

  let path =
    req
    |> request.to_uri
    |> uri.to_string
  let assert Ok(#(status, headers, body)) =
    stream_request(req.method, path, req.headers, req.body)
  let actual = response.Response(status, headers, body)

  let expected =
    response.new(200)
    |> response.prepend_header("user-agent", "hackney/1.18.2")
    |> response.prepend_header("host", "localhost:8888")
    |> response.prepend_header("connection", "keep-alive")
    |> response.prepend_header("content-length", "10000")
    |> response.set_body(bit_builder.from_string(string.repeat("a", 10_000)))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_supports_query_parameters() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Get)
    |> request.set_query([
      #("something", "123"),
      #("another", "true"),
      #("a-complicated-one", uri.percent_encode("is the thing")),
    ])

  let assert Ok(resp) = hackney.send(req)

  let expected =
    get_default_response()
    |> response.set_header("content-length", "61")
    |> response.set_body(bit_builder.from_bit_string(<<
      "something=123&another=true&a-complicated-one=is%20the%20thing":utf8,
    >>))

  string_response_should_equal(resp, expected)
}

pub fn it_handles_query_parameters_with_question_mark() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Get)
    |> request.set_query([#("?", "123")])

  let assert Ok(resp) = hackney.send(req)

  let expected =
    get_default_response()
    |> response.set_header("content-length", "5")
    |> response.set_body(bit_builder.from_bit_string(<<"?=123":utf8>>))

  string_response_should_equal(resp, expected)
}

pub fn it_doesnt_mangle_query() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Get)
  let req = request.Request(..req, query: Some("test"))

  let assert Ok(resp) = hackney.send(req)

  let expected =
    get_default_response()
    |> response.set_header("content-length", "4")
    |> response.set_body(bit_builder.from_bit_string(<<"test":utf8>>))

  string_response_should_equal(resp, expected)
}

pub fn it_supports_expect_continue_header() {
  let req =
    string.repeat("a", 1000)
    |> make_request("/", _)
    |> request.set_method(http.Post)
    |> request.prepend_header("expect", "100-continue")

  let assert Ok(resp) = hackney.send(req)

  let expected_body =
    string.repeat("a", 1000)
    |> bit_builder.from_string

  let expected =
    response.new(200)
    |> response.prepend_header("user-agent", "hackney/1.18.2")
    |> response.prepend_header("host", "localhost:8888")
    |> response.prepend_header("connection", "keep-alive")
    |> response.prepend_header("content-type", "application/octet-stream")
    |> response.prepend_header("content-length", "1000")
    |> response.prepend_header("expect", "100-continue")
    |> response.set_body(expected_body)

  string_response_should_equal(resp, expected)
}

pub fn it_sends_back_chunked_responses_test() {
  let _server = scaffold.chunked_echo_server(8889, 100)

  let req =
    string.repeat("a", 1000)
    |> make_request("/", _)
    |> request.set_host("localhost:8889")
    |> request.set_method(http.Post)

  let assert Ok(resp) = hackney.send(req)

  should.equal(resp.status, 200)
  should.equal(resp.body, string.repeat("a", 1000))
}
