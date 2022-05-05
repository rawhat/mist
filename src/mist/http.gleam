import gleam/bit_string
import gleam/string_builder.{StringBuilder}
import gleam/bit_string
import gleam/erlang/atom.{Atom}
import gleam/erlang/charlist.{Charlist}
import gleam/http
import gleam/http/request.{Request}
import gleam/http/response.{Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Option}
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import gleam/string
import mist/tcp.{LoopFn, ReceiveMessage, Tcp, TcpClosed, send}

pub type PacketType {
  Http
  HttphBin
}

pub type HttpUri {
  AbsPath(Charlist)
}

pub type Packet {
  Request(Atom, HttpUri, #(Int, Int))
  Header(Int, Atom, BitString, BitString)
}

pub type DecodedPacket {
  BinaryData(Packet, BitString)
  EndOfHeaders(BitString)
  MoreData(Option(Int))
}

pub type DecodeError {
  InvalidMethod
  UnknownHeader
}

external fn decode_packet(
  packet_type: PacketType,
  packet: BitString,
  options: List(a),
) -> Result(DecodedPacket, DecodeError) =
  "tcp_ffi" "decode_packet"

pub fn from_header(value: BitString) -> String {
  assert Ok(value) = bit_string.to_string(value)

  string.lowercase(value)
}

pub fn parse_headers(
  bs: BitString,
  headers: List(http.Header),
) -> Result(#(List(http.Header), BitString), DecodeError) {
  case decode_packet(HttphBin, bs, []) {
    Ok(BinaryData(Header(_, _field, field, value), rest)) -> {
      let field = from_header(field)
      assert Ok(value) = bit_string.to_string(value)
      parse_headers(rest, [#(field, value), ..headers])
    }
    Ok(EndOfHeaders(rest)) -> Ok(#(headers, rest))
    _ -> Error(UnknownHeader)
  }
}

/// Turns the TCP message into an HTTP request
pub fn parse_request(bs: BitString) -> Result(Request(BitString), DecodeError) {
  try BinaryData(req, rest) = decode_packet(Http, bs, [])
  assert Request(method, AbsPath(path), _version) = req

  try method =
    method
    |> atom.to_string
    |> http.parse_method
    |> result.replace_error(InvalidMethod)

  try #(headers, rest) = parse_headers(rest, [])

  let req =
    request.new()
    |> request.set_body(rest)
    |> request.set_method(method)
    |> request.set_path(charlist.to_string(path))

  Ok(request.Request(..req, headers: headers))
}

pub fn code_to_string(code: Int) -> String {
  case code {
    200 -> "Ok"
    _ -> "Unknown"
  }
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

pub fn status_to_string(status: Int) -> String {
  // Obviously nowhere near exhaustive...
  case status {
    101 -> "Switching Protocols"
    200 -> "Ok"
    201 -> "Created"
    202 -> "Accepted"
    204 -> "No Content"
    301 -> "Moved Permanently"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    404 -> "Not Found"
    405 -> "Method Not Allowed"
    500 -> "Internal Server Error"
    502 -> "Bad Gateway"
    503 -> "Service Unavailable"
    504 -> "Gateway Timeout"
  }
}

/// Turns an HTTP response into a TCP message
pub fn to_string(resp: Response(BitString)) -> BitString {
  let body_builder = case bit_string.byte_size(resp.body) {
    0 -> string_builder.from_string("")
    _size -> {
      io.println("he got dat body")
      io.debug(resp.body)
      resp.body
      |> bit_string.to_string
      |> result.unwrap("")
      |> string_builder.from_string
      |> string_builder.append("\r\n")
    }
  }

  let status_string =
    resp.status
    |> int.to_string
    |> string.append(" ")
    |> string.append(status_to_string(resp.status))

  "HTTP/1.1 "
  |> string_builder.from_string
  |> string_builder.append(status_string)
  |> string_builder.append("\r\n")
  |> string_builder.append_builder(headers(resp))
  |> string_builder.append("\r\n")
  |> string_builder.append_builder(body_builder)
  |> string_builder.to_string
  |> bit_string.from_string
}

pub fn http_response(status: Int, body: BitString) -> BitString {
  response.new(status)
  |> response.set_body(body)
  |> response.prepend_header("Content-Type", "text/plain")
  |> response.prepend_header(
    "Content-Length",
    body
    |> bit_string.byte_size
    |> fn(size) { size + 1 }
    |> int.to_string,
  )
  |> to_string
}

pub type Handler =
  fn(Request(BitString)) -> Response(BitString)

pub type HttpHandler(data) {
  HttpHandler(func: LoopFn(data), state: data)
}

/// Convert your classic `HTTP handler` into a TCP message handler.
/// You probably want to use this
pub fn make_handler(handler: Handler) -> HttpHandler(Nil) {
  HttpHandler(
    func: fn(msg, state) {
      let #(socket, _state) = state
      case msg {
        Tcp(_, _) -> {
          io.print("this should not happen")
          actor.Continue(state)
        }
        TcpClosed(_msg) -> actor.Stop(process.Normal)
        ReceiveMessage(data) -> {
          case parse_request(
            data
            |> charlist.to_string
            |> bit_string.from_string,
          ) {
            Ok(req) -> {
              assert Ok(resp) =
                req
                |> handler
                |> to_string
                |> bit_string.to_string
              assert Ok(Nil) = send(socket, charlist.from_string(resp))
            }
            Error(_) -> {
              assert Ok(error) =
                400
                |> response.new
                |> response.set_body(bit_string.from_string(""))
                |> to_string
                |> bit_string.to_string
              assert Ok(Nil) = send(socket, charlist.from_string(error))
            }
          }
          actor.Stop(process.Normal)
        }
      }
    },
    state: Nil,
  )
}
