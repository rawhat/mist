import gleam/bit_builder.{BitBuilder}
import gleam/http
import gleam/http/request
import gleam/http/response.{Response}
import gleam/hackney
import scaffold.{echo_handler, open_server, response_should_equal}

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
    [it_echoes_with_data, it_supports_large_header_fields],
  )
}

fn get_default_response() -> Response(BitBuilder) {
  response.new(200)
  |> response.prepend_header("user-agent", "hackney/1.18.1")
  |> response.prepend_header("host", "localhost:8888")
  |> response.prepend_header("content-type", "application/octet-stream")
  |> response.prepend_header("content-length", "13")
  |> response.prepend_header("connection", "keep-alive")
  |> response.set_body(bit_builder.from_bit_string(<<"hello, world!":utf8>>))
}

pub fn it_echoes_with_data() {
  let req =
    request.new()
    |> request.set_host("localhost:8888")
    |> request.set_path("/")
    |> request.set_body("hello, world!")
    |> request.set_scheme(http.Http)

  assert Ok(resp) = hackney.send(req)

  response_should_equal(resp, get_default_response())
}

pub fn it_supports_large_header_fields() {
  let big_request =
    request.new()
    |> request.set_host("localhost:8888")
    |> request.set_path("/")
    |> request.set_scheme(http.Http)
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

  assert Ok(resp) = hackney.send(big_request)

  response_should_equal(resp, expected)
}
