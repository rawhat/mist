import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/dynamic.{Dynamic}
import gleam/erlang/atom.{Atom}
import gleam/erlang/charlist.{Charlist}
import gleam/http/request.{Request}
import gleam/http/response
import gleam/http
import gleam/int
import gleam/list
import gleam/map.{Map}
import gleam/option.{Option}
import gleam/pair
import gleam/result
import gleam/string
import gleam/uri
import glisten/tcp.{Socket}
import mist/encoder
import mist/file
import mist/websocket

pub type PacketType {
  Http
  HttphBin
  HttpBin
}

pub type HttpUri {
  AbsPath(BitString)
}

pub type HttpPacket {
  HttpRequest(Dynamic, HttpUri, #(Int, Int))
  HttpHeader(Int, Atom, BitString, BitString)
}

pub type DecodedPacket {
  BinaryData(HttpPacket, BitString)
  EndOfHeaders(BitString)
  MoreData(Option(Int))
}

pub type DecodeError {
  MalformedRequest
  InvalidMethod
  InvalidPath
  UnknownHeader
  UnknownMethod
  // TODO:  better name?
  InvalidBody
  DiscardPacket
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

external fn binary_match(
  source: BitString,
  pattern: BitString,
) -> Result(#(Int, Int), Nil) =
  "http_ffi" "binary_match"

external fn string_to_int(string: Charlist, base: Int) -> Result(Int, Nil) =
  "http_ffi" "string_to_int"

const crnl = <<13:int, 10:int>>

fn read_chunk(
  socket: Socket,
  buffer: Buffer,
  body: BitBuilder,
) -> Result(BitBuilder, DecodeError) {
  case buffer.data, binary_match(buffer.data, crnl) {
    _, Ok(#(offset, _)) -> {
      assert <<
        chunk:binary-size(offset),
        _return:int,
        _newline:int,
        rest:binary,
      >> = buffer.data
      try chunk_size =
        chunk
        |> bit_string.to_string
        |> result.map(charlist.from_string)
        |> result.replace_error(InvalidBody)
      try size =
        string_to_int(chunk_size, 16)
        |> result.replace_error(InvalidBody)
      case size {
        0 -> Ok(body)
        size ->
          case rest {
            <<next_chunk:binary-size(size), 13:int, 10:int, rest:binary>> ->
              read_chunk(
                socket,
                Buffer(0, rest),
                bit_builder.append(body, next_chunk),
              )
            _ -> {
              try next = read_data(socket, Buffer(0, buffer.data), InvalidBody)
              read_chunk(socket, Buffer(0, next), body)
            }
          }
      }
    }
    <<>>, _ -> {
      try next = read_data(socket, Buffer(0, buffer.data), InvalidBody)
      read_chunk(socket, Buffer(0, next), body)
    }
    _, Error(Nil) -> Error(InvalidBody)
  }
}

/// Turns the TCP message into an HTTP request
pub fn parse_request(
  bs: BitString,
  socket: Socket,
) -> Result(request.Request(Body), DecodeError) {
  case decode_packet(HttpBin, bs, []) {
    Ok(BinaryData(HttpRequest(http_method, AbsPath(path), _version), rest)) -> {
      try method =
        http_method
        |> atom.from_dynamic
        |> result.map(atom.to_string)
        |> result.or(dynamic.string(http_method))
        |> result.nil_error
        |> result.then(http.parse_method)
        |> result.replace_error(UnknownMethod)
      try #(headers, rest) = parse_headers(rest, socket, map.new())
      try path =
        path
        |> bit_string.to_string
        |> result.replace_error(InvalidPath)
      let #(path, query) = case string.split(path, "?") {
        [path] -> #(path, [])
        [path, query_string] -> {
          let query =
            query_string
            |> uri.parse_query
            |> result.unwrap([])
          #(path, query)
        }
      }
      let req =
        request.new()
        |> request.set_body(Unread(rest, socket))
        |> request.set_method(method)
        |> request.set_path(path)
        |> request.set_query(query)
      Ok(request.Request(..req, headers: map.to_list(headers)))
    }
    _ -> Error(DiscardPacket)
  }
}

pub opaque type Body {
  Unread(rest: BitString, socket: Socket)
  Read(data: BitString)
}

pub fn read_body(req: Request(Body)) -> Result(Request(BitString), DecodeError) {
  case request.get_header(req, "transfer-encoding"), req.body {
    Ok("chunked"), Unread(rest, socket) -> {
      try chunk =
        read_chunk(socket, Buffer(remaining: 0, data: rest), bit_builder.new())
      Ok(request.set_body(req, bit_builder.to_bit_string(chunk)))
    }
    _, Unread(rest, socket) -> {
      let body_size =
        req.headers
        |> list.find(fn(tup) { pair.first(tup) == "content-length" })
        |> result.map(pair.second)
        |> result.then(int.parse)
        |> result.unwrap(0)
      let remaining = body_size - bit_string.byte_size(rest)
      case body_size, remaining {
        0, 0 -> Ok(<<>>)
        0, _n -> Ok(rest)
        // is this pipelining? check for GET?
        _n, 0 -> Ok(rest)
        _size, _rem -> read_data(socket, Buffer(remaining, rest), InvalidBody)
      }
      |> result.map(request.set_body(req, _))
      |> result.replace_error(InvalidBody)
    }
    _, Read(_data) -> Error(InvalidBody)
  }
}

pub type HttpResponseBody {
  BitBuilderBody(BitBuilder)
  FileBody(
    file_descriptor: file.FileDescriptor,
    content_type: String,
    offset: Int,
    length: Int,
  )
}

pub fn upgrade_socket(
  req: Request(Body),
) -> Result(response.Response(BitBuilder), Request(Body)) {
  try _upgrade =
    request.get_header(req, "upgrade")
    |> result.replace_error(req)
  try key =
    request.get_header(req, "sec-websocket-key")
    |> result.replace_error(req)
  try _version =
    request.get_header(req, "sec-websocket-version")
    |> result.replace_error(req)

  let accept_key = websocket.parse_key(key)

  response.new(101)
  |> response.set_body(bit_builder.new())
  |> response.prepend_header("Upgrade", "websocket")
  |> response.prepend_header("Connection", "Upgrade")
  |> response.prepend_header("Sec-WebSocket-Accept", accept_key)
  |> Ok
}

// TODO: improve this error type
pub fn upgrade(socket: Socket, req: Request(Body)) -> Result(Nil, Nil) {
  try resp =
    upgrade_socket(req)
    |> result.nil_error

  try _sent =
    resp
    |> encoder.to_bit_builder
    |> tcp.send(socket, _)
    |> result.nil_error

  Ok(Nil)
}
