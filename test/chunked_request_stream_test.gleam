import exception
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/atom
import gleam/erlang/process
import gleam/function
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/string
import glisten/socket.{type Socket, type SocketReason, Closed}
import glisten/socket/options
import glisten/tcp
import mist

const request_headers =
  "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"

pub fn it_reads_a_byte_before_the_rest_of_its_chunk_arrives_test() {
  let fragments = [
    #("4\r\n", "a"),
    #("1\r\n", "a"),
    #("0000000000000001\r", "\na"),
  ]
  list.each(fragments, fn(fragment) {
    let #(chunk_size_line, payload) = fragment
    let reading = process.new_subject()
    let handler = fn(req) {
      let assert Ok(consume) = mist.stream(req)
      process.send(reading, Nil)
      let assert Ok(mist.Chunk(data, _consume)) = consume(1)
      response.new(200)
      |> response.set_header("connection", "close")
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(data)))
    }

    use socket <- with_server(handler)
    let assert Ok(Nil) =
      tcp.send(
        socket,
        bytes_tree.from_string(request_headers <> chunk_size_line),
      )
    let assert Ok(Nil) = process.receive(reading, within: 1000)
    let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(payload))
    let assert Ok(reply) = receive_response(socket, <<>>)
    let assert Ok(reply) = bit_array.to_string(reply)
    assert string.starts_with(reply, "HTTP/1.1 200 ")
    let assert Ok(#(_headers, body)) = string.split_once(reply, "\r\n\r\n")
    assert body == "a"
  })
}

pub fn it_refuses_an_overlong_size_before_the_client_closes_test() {
  let over_limit = string.repeat("0", 17)
  list.each([over_limit, over_limit <> "\r\n"], fn(chunk_size_line) {
    let handler = fn(req) {
      let assert Ok(consume) = mist.stream(req)
      let assert Error(mist.MalformedBody) = consume(1)
      response.new(400)
      |> response.set_header("connection", "close")
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }

    use socket <- with_server(handler)
    let assert Ok(Nil) =
      tcp.send(
        socket,
        bytes_tree.from_string(request_headers <> chunk_size_line),
      )
    let assert Ok(reply) = receive_response(socket, <<>>)
    let assert Ok(reply) = bit_array.to_string(reply)
    assert string.starts_with(reply, "HTTP/1.1 400 ")
    let assert Ok(#(_headers, body)) = string.split_once(reply, "\r\n\r\n")
    assert body == ""
  })
}

pub fn it_continues_across_chunks_and_finishes_the_stream_test() {
  let first_chunk = process.new_subject()
  let handler = fn(req) {
    let assert Ok(consume) = mist.stream(req)
    let assert Ok(mist.Chunk(<<"a":utf8>>, consume)) = consume(1)
    process.send(first_chunk, Nil)
    let assert Ok(mist.Chunk(<<"bc":utf8>>, consume)) = consume(2)
    let assert Ok(mist.Chunk(<<"de":utf8>>, consume)) = consume(10)
    let assert Ok(mist.Done) = consume(1)
    response.new(200)
    |> response.set_header("connection", "close")
    |> response.set_body(mist.Bytes(bytes_tree.from_string("abcde")))
  }

  use socket <- with_server(handler)
  let assert Ok(Nil) =
    tcp.send(socket, bytes_tree.from_string(request_headers <> "2\r\nab\r\n"))
  let assert Ok(Nil) = process.receive(first_chunk, within: 1000)
  let assert Ok(Nil) =
    tcp.send(socket, bytes_tree.from_string("3\r\ncde\r\n0\r\n\r\n"))
  let assert Ok(reply) = receive_response(socket, <<>>)
  let assert Ok(reply) = bit_array.to_string(reply)
  assert string.starts_with(reply, "HTTP/1.1 200 ")
  let assert Ok(#(_headers, body)) = string.split_once(reply, "\r\n\r\n")
  assert body == "abcde"
}

fn with_server(
  handler: fn(Request(mist.Connection)) -> Response(mist.ResponseData),
  run: fn(Socket) -> Nil,
) -> Nil {
  let listening = process.new_subject()
  let assert Ok(server) =
    handler
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _address) {
      process.send(listening, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(listening, within: 1000)
  let assert Ok(socket) =
    connect(
      #(127, 0, 0, 1),
      port: port,
      options: options.to_erl_options([
        options.Mode(options.Binary),
        options.ActiveMode(options.Passive),
      ]),
      within: 1000,
    )

  let outcome = exception.rescue(fn() { run(socket) })
  let assert Ok(Nil) = tcp.close(socket)
  let monitor = process.monitor(server.pid)
  process.unlink(server.pid)
  process.send_abnormal_exit(server.pid, atom.create("shutdown"))
  let assert Ok(process.ProcessDown(..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, function.identity)
    |> process.selector_receive(1000)
  case outcome {
    Ok(Nil) -> Nil
    Error(reason) -> panic as string.inspect(reason)
  }
}

fn receive_response(
  socket: Socket,
  data: BitArray,
) -> Result(BitArray, SocketReason) {
  case tcp.receive_timeout(socket, 0, 1000) {
    Ok(next) -> receive_response(socket, <<data:bits, next:bits>>)
    Error(Closed) -> Ok(data)
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "gen_tcp", "connect")
fn connect(
  address: #(Int, Int, Int, Int),
  port port: Int,
  options options: List(options.ErlangTcpOption),
  within timeout: Int,
) -> Result(Socket, SocketReason)
