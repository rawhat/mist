import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/dynamic.{Dynamic}
import gleam/erlang/atom.{Atom}
import gleam/erlang/charlist.{Charlist}
import gleam/http/request.{Request}
import gleam/http/response.{Response}
import gleam/http
import gleam/int
import gleam/list
import gleam/map.{Map}
import gleam/option.{Option}
import gleam/pair
import gleam/result
import gleam/string
import gleam/uri
import glisten/handler.{ClientIp}
import glisten/socket.{Socket}
import glisten/socket/transport.{Transport}
import mist/internal/buffer.{Buffer}
import mist/internal/encoder

pub type Connection {
  Connection(
    body: Body,
    socket: Socket,
    transport: Transport,
    client_ip: ClientIp,
  )
}

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

pub fn from_header(value: BitString) -> String {
  let assert Ok(value) = bit_string.to_string(value)

  string.lowercase(value)
}

pub fn parse_headers(
  bs: BitString,
  socket: Socket,
  transport: Transport,
  headers: Map(String, String),
) -> Result(#(Map(String, String), BitString), DecodeError) {
  case decode_packet(HttphBin, bs, []) {
    Ok(BinaryData(HttpHeader(_, _field, field, value), rest)) -> {
      let field = from_header(field)
      let assert Ok(value) = bit_string.to_string(value)
      headers
      |> map.insert(field, value)
      |> parse_headers(rest, socket, transport, _)
    }
    Ok(EndOfHeaders(rest)) -> Ok(#(headers, rest))
    Ok(MoreData(size)) -> {
      let amount_to_read = option.unwrap(size, 0)
      use next <- result.then(read_data(
        socket,
        transport,
        Buffer(amount_to_read, bs),
        UnknownHeader,
      ))
      parse_headers(next, socket, transport, headers)
    }
    _other -> Error(UnknownHeader)
  }
}

pub fn read_data(
  socket: Socket,
  transport: Transport,
  buffer: Buffer,
  error: DecodeError,
) -> Result(BitString, DecodeError) {
  // TODO:  don't hard-code these, probably
  let to_read = int.min(buffer.remaining, 1_000_000)
  let timeout = 15_000
  use data <- result.then(
    socket
    |> transport.receive_timeout(to_read, timeout)
    |> result.replace_error(error),
  )
  let next_buffer =
    Buffer(
      remaining: int.max(0, buffer.remaining - to_read),
      data: <<buffer.data:bit_string, data:bit_string>>,
    )

  case next_buffer.remaining > 0 {
    True -> read_data(socket, transport, next_buffer, error)
    False -> Ok(next_buffer.data)
  }
}

const crnl = <<13:int, 10:int>>

pub type Chunk {
  Chunk(data: BitString, buffer: Buffer)
  Complete
}

pub fn parse_chunk(string: BitString) -> Chunk {
  case binary_split(string, <<"\r\n":utf8>>) {
    [<<"0":utf8>>, _] -> Complete
    [chunk_size, rest] -> {
      let assert Ok(chunk_size) = bit_string.to_string(chunk_size)
      case int.base_parse(chunk_size, 16) {
        Ok(size) -> {
          let size = size * 8
          case rest {
            <<
              next_chunk:bit_string-size(size),
              13:int,
              10:int,
              rest:bit_string,
            >> -> {
              Chunk(data: next_chunk, buffer: buffer.new(rest))
            }
            _ -> {
              Chunk(data: <<>>, buffer: buffer.new(string))
            }
          }
        }
        Error(_) -> {
          Chunk(data: <<>>, buffer: buffer.new(string))
        }
      }
    }

    _ -> {
      Chunk(data: <<>>, buffer: buffer.new(string))
    }
  }
}

// TODO:  use `parse_chunk` for this
fn read_chunk(
  socket: Socket,
  transport: Transport,
  buffer: Buffer,
  body: BitBuilder,
) -> Result(BitBuilder, DecodeError) {
  case buffer.data, binary_match(buffer.data, crnl) {
    _, Ok(#(offset, _)) -> {
      let assert <<
        chunk:binary-size(offset),
        _return:int,
        _newline:int,
        rest:binary,
      >> = buffer.data
      use chunk_size <- result.then(
        chunk
        |> bit_string.to_string
        |> result.map(charlist.from_string)
        |> result.replace_error(InvalidBody),
      )
      use size <- result.then(
        string_to_int(chunk_size, 16)
        |> result.replace_error(InvalidBody),
      )
      case size {
        0 -> Ok(body)
        size ->
          case rest {
            <<next_chunk:binary-size(size), 13:int, 10:int, rest:binary>> ->
              read_chunk(
                socket,
                transport,
                Buffer(0, rest),
                bit_builder.append(body, next_chunk),
              )
            _ -> {
              use next <- result.then(read_data(
                socket,
                transport,
                Buffer(0, buffer.data),
                InvalidBody,
              ))
              read_chunk(socket, transport, Buffer(0, next), body)
            }
          }
      }
    }
    <<>> as data, _ | data, Error(Nil) -> {
      use next <- result.then(read_data(
        socket,
        transport,
        Buffer(0, data),
        InvalidBody,
      ))
      read_chunk(socket, transport, Buffer(0, next), body)
    }
  }
}

/// Turns the TCP message into an HTTP request
pub fn parse_request(
  bs: BitString,
  socket: Socket,
  transport: Transport,
  client_ip: ClientIp,
) -> Result(request.Request(Connection), DecodeError) {
  case decode_packet(HttpBin, bs, []) {
    Ok(BinaryData(HttpRequest(http_method, AbsPath(path), _version), rest)) -> {
      use method <- result.then(
        http_method
        |> atom.from_dynamic
        |> result.map(atom.to_string)
        |> result.or(dynamic.string(http_method))
        |> result.nil_error
        |> result.then(http.parse_method)
        |> result.replace_error(UnknownMethod),
      )
      use #(headers, rest) <- result.then(parse_headers(
        rest,
        socket,
        transport,
        map.new(),
      ))
      use path <- result.then(
        path
        |> bit_string.to_string
        |> result.replace_error(InvalidPath),
      )
      use parsed <- result.then(
        uri.parse(path)
        |> result.replace_error(InvalidPath),
      )
      let #(path, query) = #(parsed.path, parsed.query)
      let req =
        request.new()
        |> request.set_scheme(case transport {
          transport.Ssl(..) -> http.Https
          transport.Tcp(..) -> http.Http
        })
        |> request.set_body(Connection(
          body: Initial(rest),
          socket: socket,
          transport: transport,
          client_ip: client_ip,
        ))
        |> request.set_method(method)
        |> request.set_path(path)
      Ok(request.Request(..req, query: query, headers: map.to_list(headers)))
    }
    _ -> Error(DiscardPacket)
  }
}

pub type Body {
  Initial(BitString)
}

pub fn read_body(
  req: Request(Connection),
) -> Result(Request(BitString), DecodeError) {
  let transport = case req.scheme {
    http.Https -> transport.ssl()
    http.Http -> transport.tcp()
  }
  case request.get_header(req, "transfer-encoding"), req.body.body {
    Ok("chunked"), Initial(rest) -> {
      use _nil <- result.then(handle_continue(req))

      use chunk <- result.then(read_chunk(
        req.body.socket,
        transport,
        Buffer(remaining: 0, data: rest),
        bit_builder.new(),
      ))
      Ok(request.set_body(req, bit_builder.to_bit_string(chunk)))
    }
    _, Initial(rest) -> {
      use _nil <- result.then(handle_continue(req))
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
        _size, _rem ->
          read_data(
            req.body.socket,
            transport,
            Buffer(remaining, rest),
            InvalidBody,
          )
      }
      |> result.map(request.set_body(req, _))
      |> result.replace_error(InvalidBody)
    }
  }
}

pub type BodySlice {
  Chunked(data: BitString, buffer: Buffer)
  Default(data: BitString)
  Done
}

const websocket_key = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

pub type ShaHash {
  Sha
}

fn parse_websocket_key(key: String) -> String {
  key
  |> string.append(websocket_key)
  |> crypto_hash(Sha, _)
  |> base64_encode
}

pub fn upgrade_socket(
  req: Request(Connection),
) -> Result(Response(BitBuilder), Request(Connection)) {
  use _upgrade <- result.then(
    request.get_header(req, "upgrade")
    |> result.replace_error(req),
  )
  use key <- result.then(
    request.get_header(req, "sec-websocket-key")
    |> result.replace_error(req),
  )
  use _version <- result.then(
    request.get_header(req, "sec-websocket-version")
    |> result.replace_error(req),
  )

  let accept_key = parse_websocket_key(key)

  response.new(101)
  |> response.set_body(bit_builder.new())
  |> response.prepend_header("Upgrade", "websocket")
  |> response.prepend_header("Connection", "Upgrade")
  |> response.prepend_header("Sec-WebSocket-Accept", accept_key)
  |> Ok
}

// TODO: improve this error type
pub fn upgrade(
  socket: Socket,
  transport: Transport,
  req: Request(Connection),
) -> Result(Nil, Nil) {
  use resp <- result.then(
    upgrade_socket(req)
    |> result.nil_error,
  )

  use _sent <- result.then(
    resp
    |> add_default_headers
    |> encoder.to_bit_builder
    |> transport.send(socket, _)
    |> result.nil_error,
  )

  Ok(Nil)
}

pub fn add_default_headers(resp: Response(BitBuilder)) -> Response(BitBuilder) {
  let body_size = bit_builder.byte_size(resp.body)

  let headers =
    map.from_list([
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
    |> map.to_list

  Response(..resp, headers: headers)
}

fn is_continue(req: Request(Connection)) -> Bool {
  req.headers
  |> list.find(fn(tup) {
    pair.first(tup) == "expect" && pair.second(tup) == "100-continue"
  })
  |> result.is_ok
}

pub fn handle_continue(req: Request(Connection)) -> Result(Nil, DecodeError) {
  case is_continue(req) {
    True -> {
      response.new(100)
      |> response.set_body(bit_builder.new())
      |> encoder.to_bit_builder
      |> req.body.transport.send(req.body.socket, _)
      |> result.replace_error(MalformedRequest)
    }
    False -> Ok(Nil)
  }
}

@external(erlang, "mist_ffi", "decode_packet")
fn decode_packet(
  packet_type packet_type: PacketType,
  packet packet: BitString,
  options options: List(a),
) -> Result(DecodedPacket, DecodeError)

@external(erlang, "crypto", "hash")
pub fn crypto_hash(hash hash: ShaHash, data data: String) -> String

@external(erlang, "base64", "encode")
pub fn base64_encode(data data: String) -> String

@external(erlang, "mist_ffi", "binary_match")
fn binary_match(
  source source: BitString,
  pattern pattern: BitString,
) -> Result(#(Int, Int), Nil)

@external(erlang, "mist_ffi", "string_to_int")
fn string_to_int(string string: Charlist, base base: Int) -> Result(Int, Nil)

@external(erlang, "binary", "split")
fn binary_split(source: BitString, pattern: BitString) -> List(BitString)
