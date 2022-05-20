import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/string_builder.{StringBuilder}
import gleam/bit_string
import gleam/erlang/atom.{Atom}
import gleam/http
import gleam/http/request
import gleam/http/response.{Response}
import gleam/int
import gleam/list
import gleam/option.{Option}
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import gleam/string
import glisten/tcp

pub type PacketType {
  Http
  HttphBin
  HttpBin
}

pub type HttpUri {
  AbsPath(BitString)
}

pub type HttpPacket {
  HttpRequest(Atom, HttpUri, #(Int, Int))
  HttpHeader(Int, Atom, BitString, BitString)
}

pub type DecodedPacket {
  BinaryData(HttpPacket, BitString)
  EndOfHeaders(BitString)
  MoreData(Option(Int))
}

pub type DecodeError {
  InvalidMethod
  InvalidPath
  UnknownHeader
}

external fn decode_packet(
  packet_type: PacketType,
  packet: BitString,
  options: List(a),
) -> Result(DecodedPacket, DecodeError) =
  "http_ffi" "decode_packet"

pub fn from_header(value: BitString) -> String {
  assert Ok(value) = bit_string.to_string(value)

  string.lowercase(value)
}

pub fn parse_headers(
  bs: BitString,
  headers: List(http.Header),
) -> Result(#(List(http.Header), BitString), DecodeError) {
  case decode_packet(HttphBin, bs, []) {
    Ok(BinaryData(HttpHeader(_, _field, field, value), rest)) -> {
      let field = from_header(field)
      assert Ok(value) = bit_string.to_string(value)
      parse_headers(rest, [#(field, value), ..headers])
    }
    Ok(EndOfHeaders(rest)) -> Ok(#(headers, rest))
    _ -> Error(UnknownHeader)
  }
}

/// Turns the TCP message into an HTTP request
pub fn parse_request(
  bs: BitString,
) -> Result(request.Request(BitString), DecodeError) {
  try BinaryData(req, rest) = decode_packet(HttpBin, bs, [])
  assert HttpRequest(method, AbsPath(path), _version) = req

  try method =
    method
    |> atom.to_string
    |> http.parse_method
    |> result.replace_error(InvalidMethod)

  try #(headers, rest) = parse_headers(rest, [])

  try path =
    path
    |> bit_string.to_string
    |> result.replace_error(InvalidPath)

  let req =
    request.new()
    |> request.set_body(rest)
    |> request.set_method(method)
    |> request.set_path(path)

  Ok(request.Request(..req, headers: headers))
}

pub fn headers(resp: Response(BitString)) -> StringBuilder {
  list.fold(
    resp.headers,
    string_builder.from_string(""),
    fn(builder, tup) {
      let #(header, value) = tup

      string_builder.from_strings([header, ": ", value, "\r\n"])
      |> string_builder.append_builder(builder, _)
    },
  )
}

pub fn status_to_bit_string(status: Int) -> BitString {
  // Obviously nowhere near exhaustive...
  case status {
    101 -> <<"Switching Protocols":utf8>>
    200 -> <<"Ok":utf8>>
    201 -> <<"Created":utf8>>
    202 -> <<"Accepted":utf8>>
    204 -> <<"No Content":utf8>>
    301 -> <<"Moved Permanently":utf8>>
    400 -> <<"Bad Request":utf8>>
    401 -> <<"Unauthorized":utf8>>
    403 -> <<"Forbidden":utf8>>
    404 -> <<"Not Found":utf8>>
    405 -> <<"Method Not Allowed":utf8>>
    500 -> <<"Internal Server Error":utf8>>
    502 -> <<"Bad Gateway":utf8>>
    503 -> <<"Service Unavailable":utf8>>
    504 -> <<"Gateway Timeout":utf8>>
  }
}

/// Turns an HTTP response into a TCP message
pub fn to_bit_builder(resp: Response(BitString)) -> BitBuilder {
  let body_builder = case bit_string.byte_size(resp.body) {
    0 -> bit_builder.new()
    _size ->
      bit_builder.new()
      |> bit_builder.append(resp.body)
      |> bit_builder.append(<<"\r\n":utf8>>)
  }

  let status_string =
    resp.status
    |> int.to_string
    |> bit_builder.from_string
    |> bit_builder.append(<<" ":utf8>>)
    |> bit_builder.append(status_to_bit_string(resp.status))

  bit_builder.new()
  |> bit_builder.append(<<"HTTP/1.1 ":utf8>>)
  |> bit_builder.append_builder(status_string)
  |> bit_builder.append(<<"\r\n":utf8>>)
  |> bit_builder.append_string(string_builder.to_string(headers(resp)))
  |> bit_builder.append(<<"\r\n":utf8>>)
  |> bit_builder.append_builder(body_builder)
}

pub type Handler =
  fn(request.Request(BitString)) -> Response(BitString)

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

/// This method helps turn an HTTP handler into a TCP handler that you can
/// pass to `mist.serve` or `glisten.serve`
pub fn handler(func: Handler) -> tcp.LoopFn(Nil) {
  tcp.handler(fn(msg, state) {
    let #(socket, _state) = state

    msg
    |> parse_request
    |> result.map(fn(req) {
      req
      |> func
      |> to_bit_builder
      |> tcp.send(socket, _)
      |> result.replace_error(Nil)
    })
    |> result.replace(actor.Stop(process.Normal))
    |> result.unwrap(actor.Stop(process.Normal))
  })
}
