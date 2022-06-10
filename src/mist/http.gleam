import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/erlang/atom.{Atom}
import gleam/http
import gleam/http/request.{Request}
import gleam/http/response
import gleam/int
import gleam/map.{Map}
import gleam/option.{None, Option, Some}
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import gleam/string
import glisten/tcp.{LoopState, Socket}
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

pub type Handler =
  fn(request.Request(BitString)) -> response.Response(BitBuilder)

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

pub type State {
  State(
    idle_timer: Option(process.Timer),
    upgraded_handler: Option(
      fn(websocket.Message, tcp.Socket) -> Result(Nil, Nil),
    ),
  )
}

pub fn new_state() -> State {
  State(None, None)
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

pub type HandlerResponse {
  Response(response: response.Response(HttpResponseBody))
  Upgrade(with_handler: websocket.Handler)
}

pub type HandlerFunc =
  fn(Request(BitString)) -> HandlerResponse

const stop_normal = actor.Stop(process.Normal)

/// Creates a standard HTTP handler service to pass to `mist.serve`
pub fn handler(handler: Handler) -> tcp.LoopFn(State) {
  handler_func(fn(req) {
    req
    |> handler
    |> response.map(BitBuilderBody)
    |> Response
  })
}

/// This is a more flexible handler. It will allow you to upgrade a connection
/// to a websocket connection, or deal with a regular HTTP req->resp workflow.
pub fn handler_func(handler: HandlerFunc) -> tcp.LoopFn(State) {
  tcp.handler(fn(msg, socket_state: LoopState(State)) {
    let tcp.LoopState(socket, sender, data: state) = socket_state
    case state.upgraded_handler {
      Some(handler) ->
        case websocket.frame_from_message(msg) {
          Ok(websocket.TextFrame(payload: payload, ..)) ->
            payload
            |> websocket.TextMessage
            |> handler(socket)
            |> result.replace(actor.Continue(socket_state))
            |> result.replace_error(stop_normal)
            |> result.unwrap_both
          Error(_) ->
            // TODO:  not normal
            stop_normal
        }
      None -> {
        let _ = case state.idle_timer {
          Some(t) -> process.cancel_timer(t)
          _ -> process.TimerNotFound
        }
        msg
        |> parse_request(socket)
        |> result.replace_error(stop_normal)
        |> result.map(fn(req) {
          case handler(req) {
            Response(
              response: response.Response(body: BitBuilderBody(body), ..) as resp,
            ) ->
              resp
              |> response.set_body(body)
              |> encoder.to_bit_builder
              |> tcp.send(socket, _)
              |> result.map(fn(_sent) {
                // If the handler explicitly says to close the connection, we should
                // probably listen to them
                case response.get_header(resp, "connection") {
                  Ok("close") -> {
                    tcp.close(socket)
                    stop_normal
                  }
                  _ -> {
                    // TODO:  this should be a configuration
                    let timer = process.send_after(sender, 10_000, tcp.Close)
                    actor.Continue(
                      LoopState(
                        ..socket_state,
                        data: State(..state, idle_timer: Some(timer)),
                      ),
                    )
                  }
                }
              })
              |> result.replace_error(stop_normal)
              |> result.unwrap_both
            Response(
              response: response.Response(
                body: FileBody(file_descriptor, content_type, offset, length),
                ..,
              ) as resp,
            ) -> {
              let header =
                resp
                |> response.prepend_header(
                  "content-length",
                  int.to_string(length - offset),
                )
                |> response.prepend_header("content-type", content_type)
                |> response.set_body(bit_builder.new())
                |> fn(r: response.Response(BitBuilder)) {
                  encoder.response_builder(resp.status, r.headers)
                }
              socket
              |> tcp.send(header)
              |> result.map(fn(_) {
                file.sendfile(file_descriptor, socket, offset, length, [])
              })
              |> result.replace(actor.Continue(socket_state))
              // TODO:  not normal
              |> result.replace_error(stop_normal)
              |> result.unwrap_both
            }
            Upgrade(with_handler) ->
              req
              |> websocket.upgrade(socket, _)
              |> result.replace(actor.Continue(
                LoopState(
                  ..socket_state,
                  data: State(..state, upgraded_handler: Some(with_handler)),
                ),
              ))
              // TODO:  not normal
              |> result.replace_error(stop_normal)
              |> result.unwrap_both
          }
        })
        |> result.unwrap_both
      }
    }
  })
}
