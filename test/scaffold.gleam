import gleam/bit_array
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/hackney
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import gleam/yielder
import gleeunit/should
import glisten
import glisten/internal/handler as glisten_handler
import glisten/tcp
import glisten/transport.{Tcp}
import mist
import mist/internal/handler
import mist/internal/http.{type Connection} as mhttp

pub fn with_server(
  at port: Int,
  with handler: fn(Request(Connection)) -> Response(mist.ResponseData),
  given req: Request(String),
) -> Response(String) {
  use <- open_server(port, handler)

  let assert Ok(resp) = hackney.send(req)

  resp
}

@external(erlang, "mist_ffi", "rescue")
fn rescue(func: fn() -> anything) -> Result(anything, Nil)

pub fn open_server(
  at port: Int,
  with handler: fn(Request(Connection)) -> Response(mist.ResponseData),
  after perform: fn() -> return,
) -> return {
  let pid =
    process.spawn_unlinked(fn() {
      let assert Ok(listener) = tcp.listen(port, [])
      let assert Ok(socket) = tcp.accept(listener)

      let loop_func =
        handler.with_func(fn(req) {
          req
          |> handler
          |> convert_body_types
        })

      let glisten_handler =
        glisten_handler.Handler(
          socket: socket,
          on_init: handler.init,
          on_close: option.None,
          loop: convert_loop(loop_func),
          transport: Tcp,
        )

      let assert Ok(server) = glisten_handler.start(glisten_handler)
      let assert Ok(owner) = process.subject_owner(server.data)
      let assert Ok(_nil) = tcp.controlling_process(socket, owner)
      process.send(server.data, glisten_handler.Internal(glisten_handler.Ready))

      process.sleep_forever()
    })

  case rescue(perform) {
    Ok(return) -> {
      process.kill(pid)
      return
    }
    Error(err) -> {
      process.kill(pid)
      panic as { "Handler failed with: " <> string.inspect(err) }
    }
  }
}

fn convert_body_types(
  resp: Response(mist.ResponseData),
) -> Response(mhttp.ResponseData) {
  let new_body = case resp.body {
    mist.Websocket(selector) -> mhttp.Websocket(selector)
    mist.Bytes(data) -> mhttp.Bytes(data)
    mist.File(descriptor, offset, length) ->
      mhttp.File(descriptor, offset, length)
    mist.Chunked(iter) -> mhttp.Chunked(iter)
    mist.ServerSentEvents(selector) -> mhttp.ServerSentEvents(selector)
  }
  response.set_body(resp, new_body)
}

fn map_user_selector(
  value: glisten.Message(user_message),
) -> glisten_handler.LoopMessage(user_message) {
  case value {
    glisten.Packet(msg) -> glisten_handler.Packet(msg)
    glisten.User(msg) -> glisten_handler.Custom(msg)
  }
}

fn convert_loop(
  loop: glisten.Loop(data, user_message),
) -> glisten_handler.Loop(data, user_message) {
  fn(data, msg, conn: glisten_handler.Connection(user_message)) {
    let conn = glisten.Connection(conn.socket, conn.transport, conn.sender)
    case msg {
      glisten_handler.Packet(msg) ->
        loop(data, glisten.Packet(msg), conn)
        |> glisten.map_selector(map_user_selector)
        |> glisten.convert_next
      glisten_handler.Custom(msg) ->
        loop(data, glisten.User(msg), conn)
        |> glisten.map_selector(map_user_selector)
        |> glisten.convert_next
    }
  }
}

pub fn chunked_echo_server(chunk_size: Int) {
  fn(req: request.Request(mhttp.Connection)) {
    let assert Ok(req) = mhttp.read_body(req)
    let assert Ok(body) = bit_array.to_string(req.body)
    let chunks =
      body
      |> string.to_graphemes
      |> yielder.from_list
      |> yielder.sized_chunk(chunk_size)
      |> yielder.map(fn(chars) {
        chars
        |> string.join("")
        |> bytes_tree.from_string
      })
    response.new(200)
    |> response.set_body(mist.Chunked(chunks))
  }
}

pub fn default_handler(
  req: request.Request(Connection),
) -> response.Response(mist.ResponseData) {
  let too_beeg =
    response.new(413)
    |> response.set_header("connection", "close")
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  let req = mist.read_body(req, 4_000_000)
  use <- bool.guard(when: result.is_error(req), return: too_beeg)
  let assert Ok(req) = req
  let body =
    req.query
    |> option.map(bit_array.from_string)
    |> option.unwrap(req.body)
    |> bytes_tree.from_bit_array
  let length =
    body
    |> bytes_tree.byte_size
    |> int.to_string
  let headers =
    list.filter(req.headers, fn(p) {
      case p {
        #("transfer-encoding", "chunked") -> False
        #("content-length", _) -> False
        _ -> True
      }
    })
    |> list.prepend(#("content-length", length))
  Response(status: 200, headers: headers, body: mist.Bytes(body))
}

fn compare_bitstring_body(actual: BitArray, expected: BytesTree) {
  actual
  |> bytes_tree.from_bit_array
  |> should.equal(expected)
}

fn compare_string_body(actual: String, expected: BytesTree) {
  actual
  |> bytes_tree.from_string
  |> should.equal(expected)
}

fn compare_headers_and_status(actual: Response(a), expected: Response(b)) {
  should.equal(actual.status, expected.status)

  let expected_headers = set.from_list(expected.headers)
  let actual_headers =
    actual.headers
    |> set.from_list
    |> set.filter(fn(pair) {
      let #(key, _value) = pair
      key != "date"
    })

  let missing_headers =
    set.filter(expected_headers, fn(header) {
      set.contains(actual_headers, header) == False
    })
  let extra_headers =
    set.filter(actual_headers, fn(header) {
      set.contains(expected_headers, header) == False
    })

  should.equal(missing_headers, extra_headers)
}

pub fn string_response_should_equal(
  actual: Response(String),
  expected: Response(BytesTree),
) {
  compare_headers_and_status(actual, expected)
  compare_string_body(actual.body, expected.body)
}

pub fn bitstring_response_should_equal(
  actual: Response(BitArray),
  expected: Response(BytesTree),
) {
  compare_headers_and_status(actual, expected)
  compare_bitstring_body(actual.body, expected.body)
}

pub fn make_request(path: String, body: body) -> request.Request(body) {
  request.new()
  |> request.set_host("localhost:8888")
  |> request.set_method(http.Post)
  |> request.set_path(path)
  |> request.set_body(body)
  |> request.set_scheme(http.Http)
}

type IoFormat {
  User
}

@external(erlang, "io", "fwrite")
fn io_fwrite(
  format format: IoFormat,
  output_format output_format: String,
  data data: any,
) -> Nil

pub fn io_fwrite_user(data: anything) {
  io_fwrite(User, "~tp\n", [data])
}
