import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Down, type Selector}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/pair
import gleam/result
import gleam/string
import gleam/yielder.{type Yielder}
import glisten.{type Socket}
import glisten/transport.{type Transport}
import gramps/websocket
import mist/internal/buffer.{type Buffer, Buffer}
import mist/internal/clock
import mist/internal/encoder
import mist/internal/file

pub type ResponseData {
  Websocket(Selector(Down))
  Bytes(BytesTree)
  Chunked(Yielder(BytesTree))
  File(descriptor: file.FileDescriptor, offset: Int, length: Int)
  ServerSentEvents(Selector(Down))
}

pub type Connection {
  Connection(body: Body, socket: Socket, transport: Transport)
}

pub type Handler =
  fn(Request(Connection)) -> response.Response(ResponseData)

pub type PacketType {
  Http
  HttphBin
  HttpBin
}

pub type HttpUri {
  AbsPath(BitArray)
}

pub type HttpPacket {
  HttpRequest(Dynamic, HttpUri, #(Int, Int))
  HttpHeader(Int, Atom, BitArray, BitArray)
}

pub type DecodedPacket {
  BinaryData(HttpPacket, BitArray)
  EndOfHeaders(BitArray)
  MoreData(Option(Int))
  Http2Upgrade(BitArray)
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
  NoHostHeader
  InvalidHttpVersion
}

pub fn from_header(value: BitArray) -> String {
  let assert Ok(value) = bit_array.to_string(value)

  string.lowercase(value)
}

pub fn parse_headers(
  bs: BitArray,
  socket: Socket,
  transport: Transport,
  headers: Dict(String, String),
) -> Result(#(Dict(String, String), BitArray), DecodeError) {
  case decode_packet(HttphBin, bs, []) {
    Ok(BinaryData(HttpHeader(_, _field, field, value), rest)) -> {
      let field = from_header(field)
      let assert Ok(value) = bit_array.to_string(value)
      headers
      |> dict.insert(field, value)
      |> parse_headers(rest, socket, transport, _)
    }
    Ok(EndOfHeaders(rest)) -> Ok(#(headers, rest))
    Ok(MoreData(size)) -> {
      let amount_to_read = option.unwrap(size, 0)
      use next <- result.try(read_data(
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
) -> Result(BitArray, DecodeError) {
  // TODO:  don't hard-code these, probably
  let to_read = int.min(buffer.remaining, 1_000_000)
  let timeout = 15_000
  use data <- result.try(
    socket
    |> transport.receive_timeout(transport, _, to_read, timeout)
    |> result.replace_error(error),
  )
  let next_buffer =
    Buffer(remaining: int.max(0, buffer.remaining - to_read), data: <<
      buffer.data:bits, data:bits,
    >>)

  case next_buffer.remaining > 0 {
    True -> read_data(socket, transport, next_buffer, error)
    False -> Ok(next_buffer.data)
  }
}

const crnl = <<13:int, 10:int>>

pub type Chunk {
  Chunk(data: BitArray, buffer: Buffer)
  Complete
}

pub fn parse_chunk(string: BitArray) -> Chunk {
  case binary_split(string, <<"\r\n":utf8>>) {
    [<<"0":utf8>>, _] -> Complete
    [chunk_size, rest] -> {
      let assert Ok(chunk_size) = bit_array.to_string(chunk_size)
      case int.base_parse(chunk_size, 16) {
        Ok(size) -> {
          let size = size * 8
          case rest {
            <<next_chunk:bits-size(size), 13:int, 10:int, rest:bits>> -> {
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
  body: BytesTree,
) -> Result(BytesTree, DecodeError) {
  case buffer.data, binary_match(buffer.data, crnl) {
    _, Ok(#(offset, _)) -> {
      let assert <<
        chunk:bytes-size(offset),
        _return:int,
        _newline:int,
        rest:bytes,
      >> = buffer.data
      use chunk_size <- result.try(
        chunk
        |> bit_array.to_string
        |> result.map(charlist.from_string)
        |> result.replace_error(InvalidBody),
      )
      use size <- result.try(
        string_to_int(chunk_size, 16)
        |> result.replace_error(InvalidBody),
      )
      case size {
        0 -> Ok(body)
        size ->
          case rest {
            <<next_chunk:bytes-size(size), 13:int, 10:int, rest:bytes>> ->
              read_chunk(
                socket,
                transport,
                Buffer(0, rest),
                bytes_tree.append(body, next_chunk),
              )
            _ -> {
              use next <- result.try(read_data(
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
      use next <- result.try(read_data(
        socket,
        transport,
        Buffer(0, data),
        InvalidBody,
      ))
      read_chunk(socket, transport, Buffer(0, next), body)
    }
  }
}

pub type HttpVersion {
  Http1
  Http11
}

pub fn version_to_string(version: HttpVersion) {
  case version {
    Http1 -> "1.0"
    Http11 -> "1.1"
  }
}

pub type ParsedRequest {
  Http1Request(request: request.Request(Connection), version: HttpVersion)
  Upgrade(BitArray)
}

@external(erlang, "mist_ffi", "decode_atom")
fn decode_atom(value: Dynamic) -> Result(atom.Atom, Nil)

fn decode_http_method(value: Dynamic) -> Result(http.Method, Nil) {
  let options = atom.create("OPTIONS")
  let get = atom.create("GET")
  let head = atom.create("HEAD")
  let post = atom.create("POST")
  let put = atom.create("PUT")
  let delete = atom.create("DELETE")
  let trace = atom.create("TRACE")

  case decode_atom(value) {
    Ok(method) if method == options -> Ok(http.Options)
    Ok(method) if method == get -> Ok(http.Get)
    Ok(method) if method == head -> Ok(http.Head)
    Ok(method) if method == post -> Ok(http.Post)
    Ok(method) if method == put -> Ok(http.Put)
    Ok(method) if method == delete -> Ok(http.Delete)
    Ok(method) if method == trace -> Ok(http.Trace)
    _ -> {
      case decode.run(value, decode.string) {
        Ok(str) -> http.parse_method(str)
        _ -> Error(Nil)
      }
    }
  }
}

/// Turns the TCP message into an HTTP request
pub fn parse_request(
  bs: BitArray,
  conn: Connection,
) -> Result(ParsedRequest, DecodeError) {
  case decode_packet(HttpBin, bs, []) {
    Ok(BinaryData(HttpRequest(http_method, AbsPath(path), version), rest)) -> {
      use method <- result.try(
        http_method
        |> decode_http_method
        |> result.replace_error(UnknownMethod),
      )
      use #(headers, rest) <- result.try(parse_headers(
        rest,
        conn.socket,
        conn.transport,
        dict.new(),
      ))
      use path <- result.try(
        path
        |> bit_array.to_string
        |> result.replace_error(InvalidPath),
      )
      use #(path, query) <- result.try(
        get_path_and_query(path)
        |> result.replace_error(InvalidPath),
      )
      let scheme = case conn.transport {
        transport.Ssl(..) -> http.Https
        transport.Tcp(..) -> http.Http
      }
      use host_header <- result.try(
        dict.get(headers, "host")
        |> result.replace_error(NoHostHeader),
      )
      let #(hostname, port) =
        host_header
        |> string.split_once(":")
        |> result.unwrap(#(host_header, ""))
      let port =
        int.parse(port)
        |> result.map_error(fn(_err) {
          case scheme {
            http.Https -> 443
            http.Http -> 80
          }
        })
        |> result.unwrap_both
      let req =
        request.Request(
          body: Connection(..conn, body: Initial(rest)),
          headers: dict.to_list(headers),
          host: hostname,
          method: method,
          path: path,
          port: option.Some(port),
          query: option.from_result(query),
          scheme: scheme,
        )
      case version {
        #(1, 0) -> Ok(Http1Request(request: req, version: Http1))
        #(1, 1) -> Ok(Http1Request(request: req, version: Http11))
        _ -> Error(InvalidHttpVersion)
      }
    }
    // "\r\nSM\r\n\r\n"
    Ok(Http2Upgrade(<<
      13:int,
      10:int,
      83:int,
      77:int,
      13:int,
      10:int,
      13:int,
      10:int,
      data:bits,
    >>)) -> {
      Ok(Upgrade(data))
    }
    Ok(MoreData(size)) -> {
      let amount_to_read = option.unwrap(size, 0)
      use next <- result.try(read_data(
        conn.socket,
        conn.transport,
        Buffer(amount_to_read, bs),
        MalformedRequest,
      ))
      parse_request(next, conn)
    }
    _ -> Error(DiscardPacket)
  }
}

pub type Body {
  Initial(BitArray)
  Stream(
    selector: Selector(BitArray),
    data: BitArray,
    remaining: Int,
    attempts: Int,
  )
}

pub fn read_body(
  req: Request(Connection),
) -> Result(Request(BitArray), DecodeError) {
  let transport = case req.scheme {
    http.Https -> transport.Ssl
    http.Http -> transport.Tcp
  }
  case request.get_header(req, "transfer-encoding"), req.body.body {
    Ok("chunked"), Initial(rest) -> {
      use _nil <- result.try(handle_continue(req))

      use chunk <- result.try(read_chunk(
        req.body.socket,
        transport,
        Buffer(remaining: 0, data: rest),
        bytes_tree.new(),
      ))
      Ok(request.set_body(req, bytes_tree.to_bit_array(chunk)))
    }
    _, Initial(rest) -> {
      use _nil <- result.try(handle_continue(req))
      let body_size =
        req.headers
        |> list.find(fn(tup) { pair.first(tup) == "content-length" })
        |> result.map(pair.second)
        |> result.try(int.parse)
        |> result.unwrap(0)
      let remaining = body_size - bit_array.byte_size(rest)
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
    _,
      Stream(
        selector: selector,
        data: data,
        remaining: remaining,
        attempts: attempts,
      )
      if remaining > 0
    -> {
      let res =
        selector
        |> process.selector_receive(1000)
        |> result.replace_error(InvalidBody)
      use next <- result.try(res)
      let got = bit_array.byte_size(next)
      let left = int.max(remaining - got, 0)
      let new_data = bit_array.append(data, next)
      case left {
        0 -> Ok(request.set_body(req, new_data))
        _rem ->
          read_body(request.set_body(
            req,
            Connection(
              ..req.body,
              body: Stream(selector, new_data, left, attempts + 1),
            ),
          ))
      }
    }
    _, Stream(data: data, ..) -> {
      Ok(request.set_body(req, data))
    }
  }
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
  extensions: List(String),
) -> Result(Response(BytesTree), Request(Connection)) {
  use _upgrade <- result.try(
    request.get_header(req, "upgrade")
    |> result.replace_error(req),
  )
  use key <- result.try(
    request.get_header(req, "sec-websocket-key")
    |> result.replace_error(req),
  )
  use _version <- result.try(
    request.get_header(req, "sec-websocket-version")
    |> result.replace_error(req),
  )

  let permessage_deflate = websocket.has_deflate(extensions)

  let accept_key = parse_websocket_key(key)

  let resp =
    response.new(101)
    |> response.set_body(bytes_tree.new())
    |> response.prepend_header("upgrade", "websocket")
    |> response.prepend_header("connection", "Upgrade")
    |> response.prepend_header("sec-websocket-accept", accept_key)

  case permessage_deflate {
    True ->
      Ok(response.prepend_header(
        resp,
        "sec-websocket-extensions",
        "permessage-deflate",
      ))
    False -> Ok(resp)
  }
}

// TODO: improve this error type
pub fn upgrade(
  socket: Socket,
  transport: Transport,
  extensions: List(String),
  req: Request(Connection),
) -> Result(Nil, Nil) {
  use resp <- result.try(
    upgrade_socket(req, extensions)
    |> result.replace_error(Nil),
  )

  use _sent <- result.try(
    resp
    |> add_default_headers(req.method == http.Head)
    |> maybe_keep_alive
    |> encoder.to_bytes_tree("1.1")
    |> transport.send(transport, socket, _)
    |> result.replace_error(Nil),
  )

  Ok(Nil)
}

pub fn add_date_header(resp: Response(any)) -> Response(any) {
  case response.get_header(resp, "date") {
    Error(_nil) -> response.set_header(resp, "date", clock.get_date())
    _ -> resp
  }
}

pub fn connection_close(resp: Response(any)) -> Response(any) {
  response.set_header(resp, "connection", "close")
}

pub fn keep_alive(resp: Response(any)) -> Response(any) {
  response.set_header(resp, "connection", "keep-alive")
}

pub fn maybe_keep_alive(resp: Response(any)) -> Response(any) {
  case response.get_header(resp, "connection") {
    Ok(_) -> resp
    _ -> response.set_header(resp, "connection", "keep-alive")
  }
}

fn maybe_drop_body(
  resp: Response(BytesTree),
  is_head_request: Bool,
) -> Response(BytesTree) {
  case is_head_request {
    True -> response.set_body(resp, bytes_tree.new())
    False -> resp
  }
}

pub fn add_content_length(
  when when: Bool,
  length length: Int,
) -> fn(Response(any)) -> Response(any) {
  fn(resp: Response(any)) {
    case when {
      True -> {
        let #(_existing, headers) =
          resp.headers
          |> list.key_pop("content-length")
          |> result.lazy_unwrap(fn() { #("", resp.headers) })

        Response(..resp, headers: headers)
        |> response.set_header("content-length", int.to_string(length))
      }
      False -> resp
    }
  }
}

pub fn add_default_headers(
  resp: Response(BytesTree),
  is_head_response: Bool,
) -> Response(BytesTree) {
  let body_size = bytes_tree.byte_size(resp.body)
  let #(_existing_content_length, headers) =
    resp.headers
    |> list.key_pop("content-length")
    |> result.lazy_unwrap(fn() { #("", resp.headers) })

  let resp = case resp.status, body_size {
    // explicitly drop
    n, _ if n >= 100 && n <= 199 -> Response(..resp, headers:)
    // explicitly drop
    n, _ if n == 204 -> Response(..resp, headers:)
    // don't add, don't drop
    n, 0 if n == 304 -> resp
    // don't add, don't drop
    _, 0 if is_head_response == True -> resp
    // explicitly overwrite
    _, _ ->
      response.set_header(resp, "content-length", int.to_string(body_size))
  }

  resp
  |> add_date_header
  |> maybe_drop_body(is_head_response)
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
      |> response.set_body(bytes_tree.new())
      |> encoder.to_bytes_tree("1.1")
      |> transport.send(req.body.transport, req.body.socket, _)
      |> result.replace_error(MalformedRequest)
    }
    False -> Ok(Nil)
  }
}

@external(erlang, "mist_ffi", "decode_packet")
fn decode_packet(
  packet_type packet_type: PacketType,
  packet packet: BitArray,
  options options: List(a),
) -> Result(DecodedPacket, DecodeError)

@external(erlang, "crypto", "hash")
pub fn crypto_hash(hash hash: ShaHash, data data: String) -> String

@external(erlang, "base64", "encode")
pub fn base64_encode(data data: String) -> String

@external(erlang, "mist_ffi", "binary_match")
fn binary_match(
  source source: BitArray,
  pattern pattern: BitArray,
) -> Result(#(Int, Int), Nil)

@external(erlang, "mist_ffi", "string_to_int")
fn string_to_int(string string: Charlist, base base: Int) -> Result(Int, Nil)

@external(erlang, "binary", "split")
fn binary_split(source: BitArray, pattern: BitArray) -> List(BitArray)

@external(erlang, "mist_ffi", "get_path_and_query")
fn get_path_and_query(
  str: String,
) -> Result(#(String, Result(String, Nil)), #(value, term))
