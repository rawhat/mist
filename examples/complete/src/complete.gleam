import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import logging
import mist.{type Connection, type ResponseData}

const index = "<html lang='en'>
  <head>
    <title>Mist Example</title>
  </head>
  <body>
    Hello, world!
  </body>
</html>"

pub fn main() {
  logging.configure()
  logging.set_level(logging.Debug)

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_tree.new()))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(req) {
        [] ->
          response.new(200)
          |> response.prepend_header("my-value", "abc")
          |> response.prepend_header("my-value", "123")
          |> response.set_body(mist.Bytes(bytes_tree.from_string(index)))
        ["ws"] ->
          mist.websocket(
            request: req,
            on_init: fn(_conn) { #(Nil, None) },
            on_close: fn(_state) { io.println("goodbye!") },
            handler: handle_ws_message,
          )
        ["echo"] -> echo_body(req)
        ["chunk"] ->
          mist.chunked(
            req,
            response.new(200),
            fn(subj) {
              process.spawn(fn() { send_chunks(subj) })
              Nil
            },
            fn(state, msg, connection) {
              case msg {
                Data(str) -> {
                  let assert Ok(_nil) =
                    mist.send_chunk(connection, bit_array.from_string(str))
                  mist.chunk_continue(state)
                }
                Done -> {
                  mist.chunk_stop()
                }
              }
            },
          )
        ["file", ..rest] -> serve_file(req, rest)
        ["stream"] -> handle_stream(req)

        _ -> not_found
      }
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.with_ipv6
    |> mist.port(4000)
    |> mist.start

  process.sleep_forever()
}

pub type MyMessage {
  Broadcast(String)
}

fn handle_ws_message(state, message, conn) {
  case message {
    mist.Text("ping") -> {
      let assert Ok(_) = mist.send_text_frame(conn, "pong")
      mist.continue(state)
    }
    mist.Text(msg) -> {
      logging.log(logging.Info, "Received text frame: " <> msg)
      mist.continue(state)
    }
    mist.Binary(msg) -> {
      logging.log(
        logging.Info,
        "Received binary frame ("
          <> int.to_string(bit_array.byte_size(msg))
          <> ")",
      )
      mist.continue(state)
    }
    mist.Custom(Broadcast(text)) -> {
      let assert Ok(_) = mist.send_text_frame(conn, text)
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn echo_body(request: Request(Connection)) -> Response(ResponseData) {
  let content_type =
    request
    |> request.get_header("content-type")
    |> result.unwrap("text/plain")

  mist.read_body(request, 1024 * 1024 * 10)
  |> result.map(fn(req) {
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(req.body)))
    |> response.set_header("content-type", content_type)
  })
  |> result.lazy_unwrap(fn() {
    response.new(400)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  })
}

type ChunkMessage {
  Data(data: String)
  Done
}

fn send_chunks(subject: Subject(ChunkMessage)) {
  ["one", "two", "three"]
  |> list.each(fn(data) {
    process.sleep(2000)
    process.send(subject, Data(data))
  })
  process.send(subject, Done)
}

fn serve_file(
  _req: Request(Connection),
  path: List(String),
) -> Response(ResponseData) {
  let file_path = string.join(path, "/")

  // Omitting validation for brevity
  mist.send_file(file_path, offset: 0, limit: None)
  |> result.map(fn(file) {
    let content_type = guess_content_type(file_path)
    response.new(200)
    |> response.prepend_header("content-type", content_type)
    |> response.set_body(file)
  })
  |> result.lazy_unwrap(fn() {
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  })
}

fn handle_stream(req: Request(Connection)) -> Response(ResponseData) {
  let failed =
    response.new(400) |> response.set_body(mist.Bytes(bytes_tree.new()))
  case mist.stream(req) {
    Ok(consume) -> {
      case do_handle_stream(consume, <<>>) {
        Ok(body) ->
          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
        Error(_reason) -> failed
      }
    }
    Error(_reason) -> {
      failed
    }
  }
}

fn do_handle_stream(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  body: BitArray,
) -> Result(BitArray, Nil) {
  case consume(1024) {
    Ok(mist.Chunk(data, consume)) ->
      do_handle_stream(consume, <<body:bits, data:bits>>)
    Ok(mist.Done) -> Ok(body)
    Error(_reason) -> Error(Nil)
  }
}

fn guess_content_type(_path: String) -> String {
  "application/octet-stream"
}
