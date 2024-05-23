import gleam/bit_array
import gleam/bytes_builder.{type BytesBuilder}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response, Response}
import gleam/option.{Some}
import gleam/string
import gleam/uri
import gleeunit/should
import scaffold.{
  bitstring_response_should_equal, make_request, string_response_should_equal,
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

fn get_default_response() -> Response(BytesBuilder) {
  response.new(200)
  |> response.prepend_header("user-agent", "hackney/1.20.1")
  |> response.prepend_header("host", "localhost:8888")
  |> response.prepend_header("content-type", "application/octet-stream")
  |> response.prepend_header("content-length", "13")
  |> response.prepend_header("connection", "keep-alive")
  |> response.set_body(bytes_builder.from_bit_array(<<"hello, world!":utf8>>))
}

pub fn it_echoes_with_data_test() {
  let req = make_request("/", "hello, world!")
  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  string_response_should_equal(resp, get_default_response())
}

pub fn it_supports_large_header_fields_test() {
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
    |> response.set_body(bytes_builder.from_bit_array(<<>>))

  let resp = scaffold.with_server(8888, scaffold.default_handler, big_request)

  string_response_should_equal(resp, expected)
}

pub fn it_supports_patch_requests_test() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Patch)

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  string_response_should_equal(resp, get_default_response())
}

pub fn it_rejects_large_requests_test() {
  let req =
    string.repeat("a", 4_000_001)
    |> make_request("/", _)

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected =
    response.new(413)
    |> response.set_body(bytes_builder.from_bit_array(<<>>))
    |> response.prepend_header("content-length", "0")
    |> response.prepend_header("connection", "close")

  string_response_should_equal(resp, expected)
}

@external(erlang, "hackney_ffi", "stream_request")
fn stream_request(
  method method: http.Method,
  path path: String,
  headers headers: List(#(String, String)),
  body body: BitArray,
) -> Result(#(Int, List(#(String, String)), BitArray), Nil)

pub fn it_supports_chunked_encoding_test() {
  let req =
    string.repeat("a", 10_000)
    |> bit_array.from_string
    |> make_request("/", _)
    |> request.set_method(http.Post)
    |> request.prepend_header("transfer-encoding", "chunked")

  let path =
    req
    |> request.to_uri
    |> uri.to_string

  use <- scaffold.open_server(8888, scaffold.default_handler)

  let assert Ok(#(status, headers, body)) =
    stream_request(req.method, path, req.headers, req.body)
  let actual = response.Response(status, headers, body)

  let expected =
    response.new(200)
    |> response.prepend_header("user-agent", "hackney/1.20.1")
    |> response.prepend_header("host", "localhost:8888")
    |> response.prepend_header("connection", "keep-alive")
    |> response.prepend_header("content-length", "10000")
    |> response.set_body(bytes_builder.from_string(string.repeat("a", 10_000)))

  bitstring_response_should_equal(actual, expected)
}

pub fn it_supports_query_parameters_test() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Get)
    |> request.set_query([
      #("something", "123"),
      #("another", "true"),
      #("a-complicated-one", "is the thing"),
    ])

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected =
    get_default_response()
    |> response.set_header("content-length", "61")
    |> response.set_body(
      bytes_builder.from_bit_array(<<
        "something=123&another=true&a-complicated-one=is%20the%20thing":utf8,
      >>),
    )

  string_response_should_equal(resp, expected)
}

pub fn it_handles_query_parameters_with_question_mark_test() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Get)
    |> request.set_query([#("?", "123")])

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected =
    get_default_response()
    |> response.set_header("content-length", "7")
    |> response.set_body(bytes_builder.from_bit_array(<<"%3F=123":utf8>>))

  string_response_should_equal(resp, expected)
}

pub fn it_doesnt_mangle_query_test() {
  let req =
    make_request("/", "hello, world!")
    |> request.set_method(http.Get)
  let req = request.Request(..req, query: Some("test"))

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected =
    get_default_response()
    |> response.set_header("content-length", "4")
    |> response.set_body(bytes_builder.from_bit_array(<<"test":utf8>>))

  string_response_should_equal(resp, expected)
}

pub fn it_supports_expect_continue_header_test() {
  let req =
    string.repeat("a", 1000)
    |> make_request("/", _)
    |> request.set_method(http.Post)
    |> request.prepend_header("expect", "100-continue")

  let resp = scaffold.with_server(8888, scaffold.default_handler, req)

  let expected_body =
    string.repeat("a", 1000)
    |> bytes_builder.from_string

  let expected =
    response.new(200)
    |> response.prepend_header("user-agent", "hackney/1.20.1")
    |> response.prepend_header("host", "localhost:8888")
    |> response.prepend_header("connection", "keep-alive")
    |> response.prepend_header("content-type", "application/octet-stream")
    |> response.prepend_header("content-length", "1000")
    |> response.prepend_header("expect", "100-continue")
    |> response.set_body(expected_body)

  string_response_should_equal(resp, expected)
}

pub fn it_sends_back_chunked_responses_test() {
  let req =
    string.repeat("a", 1000)
    |> make_request("/", _)
    |> request.set_host("localhost:8888")
    |> request.set_method(http.Post)

  let handler = scaffold.chunked_echo_server(100)

  let resp = scaffold.with_server(8888, handler, req)

  should.equal(resp.status, 200)
  should.equal(resp.body, string.repeat("a", 1000))
}

pub fn it_allows_multiple_headers_test() {
  // TODO:  fix
  should.equal(False, True)
}
