import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/iterator
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging
import mist.{type Connection, type ResponseData}

@external(erlang, "logger", "update_primary_config")
fn logger_update_primary_config(config: Dict(Atom, Atom)) -> Result(Nil, any)

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
  let _ =
    logger_update_primary_config(
      dict.from_list([
        #(atom.create_from_string("level"), atom.create_from_string("debug")),
      ]),
    )
  // These values are for the Websocket process initialized below
  let selector = process.new_selector()
  let state = Nil

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_builder.new()))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      logging.log(
        logging.Info,
        "Got a request from: " <> string.inspect(mist.get_client_info(req.body)),
      )
      case request.path_segments(req) {
        [] ->
          response.new(200)
          |> response.prepend_header("my-value", "abc")
          |> response.prepend_header("my-value", "123")
          |> response.set_body(mist.Bytes(bytes_builder.from_string(index)))
        ["ws"] ->
          mist.websocket(
            request: req,
            on_init: fn(_conn) { #(state, Some(selector)) },
            on_close: fn(_state) { io.println("goodbye!") },
            handler: handle_ws_message,
          )
        ["echo"] -> echo_body(req)
        ["chunk"] -> serve_chunk(req)
        ["file", ..rest] -> serve_file(req, rest)
        ["form"] -> handle_form(req)

        _ -> not_found
      }
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.with_ipv6
    |> mist.port(0)
    |> mist.start_http

  process.sleep_forever()
}

pub type MyMessage {
  Broadcast(String)
}

fn handle_ws_message(state, conn, message) {
  case message {
    mist.Text("ping") -> {
      let assert Ok(_) = mist.send_text_frame(conn, "pong")
      actor.continue(state)
    }
    mist.Text(_) | mist.Binary(_) -> {
      actor.continue(state)
    }
    mist.Custom(Broadcast(text)) -> {
      let assert Ok(_) = mist.send_text_frame(conn, text)
      actor.continue(state)
    }
    mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
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
    |> response.set_body(mist.Bytes(bytes_builder.from_bit_array(req.body)))
    |> response.set_header("content-type", content_type)
  })
  |> result.lazy_unwrap(fn() {
    response.new(400)
    |> response.set_body(mist.Bytes(bytes_builder.new()))
  })
}

fn serve_chunk(_request: Request(Connection)) -> Response(ResponseData) {
  let iter =
    ["one", "two", "three"]
    |> iterator.from_list
    |> iterator.map(fn(data) {
      process.sleep(2000)
      data
    })
    |> iterator.map(bytes_builder.from_string)

  response.new(200)
  |> response.set_body(mist.Chunked(iter))
  |> response.set_header("content-type", "text/plain")
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
    |> response.set_body(mist.Bytes(bytes_builder.new()))
  })
}

fn handle_form(req: Request(Connection)) -> Response(ResponseData) {
  let _req = mist.read_body(req, 1024 * 1024 * 30)
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_builder.new()))
}

fn guess_content_type(_path: String) -> String {
  "application/octet-stream"
}
