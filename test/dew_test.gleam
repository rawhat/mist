import gleam/bit_string
import gleam/http as ghttp
import gleam/http/request
import gleeunit
import gleeunit/should
import dew.{parse_request}

pub fn main() {
  gleeunit.main()
}

pub fn parse_request_test() {
  let bs =
    "GET / HTTP/1.1
Host: localhost:8001
User-Agent: curl/7.82.0
Accept: */*

hello, world!"
    |> bit_string.from_string

  let req =
    request.new()
    |> request.set_body(bit_string.from_string(""))
    |> request.set_method(ghttp.Get)
    |> request.set_path("/")
    |> request.prepend_header("Host", "localhost:8001")
    |> request.prepend_header("User-Agent", "curl/7.82.0")
    |> request.prepend_header("Accept", "*/*")
    |> request.set_body(bit_string.from_string("hello, world!"))
    |> Ok

  parse_request(bs)
  |> should.equal(req)
}
