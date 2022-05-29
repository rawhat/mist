import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/erlang/atom.{Atom}
import gleam/http
import gleam/http/request
import gleam/http/response.{Response}
import gleam/int
import gleam/list
import gleam/map.{Map}
import gleam/option.{Option, Some}
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import gleam/string
import glisten/tcp.{LoopState, Socket}

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
  // TODO:  better name?
  InvalidBody
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

pub type Buffer {
  Buffer(remaining: Int, data: BitString)
}

pub fn parse_headers(
  bs: BitString,
  socket: Socket,
  headers: Map(String, String),
) -> Result(#(Map(String, String), BitString), DecodeError) {
  case decode_packet(HttphBin, bs, []) {
    Ok(BinaryData(HttpHeader(_, _field, field, value), rest)) -> {
      let field = from_header(field)
      assert Ok(value) = bit_string.to_string(value)
      headers
      |> map.insert(field, value)
      |> parse_headers(rest, socket, _)
    }
    Ok(EndOfHeaders(rest)) -> Ok(#(headers, rest))
    Ok(MoreData(size)) -> {
      let amount_to_read = option.unwrap(size, 0)
      try next = read_data(socket, Buffer(amount_to_read, bs), UnknownHeader)
      parse_headers(next, socket, headers)
    }
    _other -> Error(UnknownHeader)
  }
}

pub fn read_data(
  socket: Socket,
  buffer: Buffer,
  error: DecodeError,
) -> Result(BitString, DecodeError) {
  // TODO:  don't hard-code these, probably
  let to_read = int.min(buffer.remaining, 1_000_000)
  let timeout = 15_000
  try data =
    socket
    |> tcp.receive_timeout(to_read, timeout)
    |> result.replace_error(error)
  let next_buffer =
    Buffer(
      remaining: buffer.remaining - to_read,
      data: <<buffer.data:bit_string, data:bit_string>>,
    )

  case next_buffer.remaining > 0 {
    True -> read_data(socket, next_buffer, error)
    False -> Ok(next_buffer.data)
  }
}

/// Turns the TCP message into an HTTP request
pub fn parse_request(
  bs: BitString,
  socket: Socket,
) -> Result(request.Request(BitString), DecodeError) {
  try BinaryData(req, rest) = decode_packet(HttpBin, bs, [])
  assert HttpRequest(method, AbsPath(path), _version) = req

  try method =
    method
    |> atom.to_string
    |> http.parse_method
    |> result.replace_error(InvalidMethod)

  try #(headers, rest) = parse_headers(rest, socket, map.new())

  try path =
    path
    |> bit_string.to_string
    |> result.replace_error(InvalidPath)

  let body_size =
    headers
    |> map.get("content-length")
    |> result.then(int.parse)
    |> result.unwrap(0)

  let remaining = body_size - bit_string.byte_size(rest)
  try body = case body_size, remaining {
    0, 0 -> Ok(<<>>)
    0, _n ->
      // is this pipelining? check for GET?
      Ok(rest)
    _n, 0 -> Ok(rest)
    _size, _rem -> read_data(socket, Buffer(remaining, rest), InvalidBody)
  }

  let req =
    request.new()
    |> request.set_body(body)
    |> request.set_method(method)
    |> request.set_path(path)

  Ok(request.Request(..req, headers: map.to_list(headers)))
}

pub fn encode_headers(headers: map.Map(String, String)) -> BitBuilder {
  map.fold(
    headers,
    bit_builder.new(),
    fn(builder, header, value) {
      builder
      |> bit_builder.append_string(header)
      |> bit_builder.append(<<": ":utf8>>)
      |> bit_builder.append_string(value)
      |> bit_builder.append(<<"\r\n":utf8>>)
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
pub fn to_bit_builder(resp: Response(BitBuilder)) -> BitBuilder {
  let body_size = bit_builder.byte_size(resp.body)

  let headers =
    map.from_list([
      #("content-type", "text/plain; charset=utf-8"),
      #("content-length", int.to_string(body_size)),
      #("connection", "keep-alive"),
    ])
    |> list.fold(
      resp.headers,
      _,
      fn(defaults, tup) {
        let #(key, value) = tup
        map.insert(defaults, key, value)
      },
    )

  let body_builder = case body_size {
    0 -> bit_builder.new()
    _size ->
      bit_builder.new()
      |> bit_builder.append_builder(resp.body)
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
  |> bit_builder.append_builder(encode_headers(headers))
  |> bit_builder.append(<<"\r\n":utf8>>)
  |> bit_builder.append_builder(body_builder)
}

pub type Handler =
  fn(request.Request(BitString)) -> Response(BitBuilder)

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

/// This method helps turn an HTTP handler into a TCP handler that you can
/// pass to `mist.serve` or `glisten.serve`
pub fn handler(func: Handler) -> tcp.LoopFn(Option(process.Timer)) {
  tcp.handler(fn(msg, state) {
    let tcp.LoopState(socket, sender, data: timer) = state
    let _ = case timer {
      Some(t) -> process.cancel_timer(t)
      _ -> process.TimerNotFound
    }

    // TODO:  notify about malformed requests here, as well
    assert Ok(req) = parse_request(msg, socket)
    let resp = func(req)

    let raw_response = to_bit_builder(resp)
    assert Ok(_) = tcp.send(socket, raw_response)

    // If the handler explicitly says to close the connection, we should
    // probably listen to them
    case response.get_header(resp, "connection") {
      Ok("close") -> {
        tcp.close(socket)
        actor.Stop(process.Normal)
      }
      _ -> {
        // TODO:  this should be a configuration
        let timer = process.send_after(sender, 10_000, tcp.Close)
        actor.Continue(LoopState(..state, data: Some(timer)))
      }
    }
  })
}
