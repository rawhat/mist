# mist

A glistening Gleam web server.

## Installation

This package can be added to your Gleam project:

```sh
gleam add mist
```

and its documentation can be found at <https://hexdocs.pm/mist>.

## Usage

The main entrypoints for your application are `mist.start_http` and
`mist.start_https`. The argument to these functions is generated from the
opaque `Builder` type. It can be constructed with the `mist.new` function, and
fed updated configuration options with the associated methods (demonstrated
in the examples below).

```gleam
import gleam/bit_builder
import gleam/bit_string
import gleam/erlang/process
import gleam/http/request.{Request}
import gleam/http/response.{Response}
import gleam/iterator
import gleam/otp/actor
import gleam/result
import gleam/string
import mist/file
import mist.{Connection, ResponseData}

pub fn main() {
  // This would be the selector for the hypothetic pubsub system messages
  let selector = process.new_selector()
  let state = Nil

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bit_builder.new()))

  fn(req: Request(Connection)) -> Response(ResponseData) {
    case request.path_segments(req) {
      ["ws"] ->
        mist.websocket(req)
        |> mist.with_state(state)
        |> mist.selecting(selector)
        |> mist.on_message(handle_ws_message)
        |> mist.upgrade
      ["echo"] -> echo_body(req)
      ["chunk"] -> serve_chunk(req)
      ["file", ..rest] -> serve_file(req, rest)
      ["form"] -> handle_form(req)

      _ -> not_found
    }
  }
  |> mist.new
  |> mist.port(8080)
  |> mist.start_http

  process.sleep_forever()
}

pub type MyMessage {
  Broadcast(String)
}

fn handle_ws_message(state, conn, message) {
  case message {
    mist.Text(<<"ping":utf8>>) -> {
      let assert Ok(_) = mist.send_text_frame(conn, <<"pong":utf8>>)
      actor.Continue(state)
    }
    mist.Text(_) | mist.Binary(_) -> {
      actor.Continue(state)
    }
    mist.Custom(Broadcast(text)) -> {
      let assert Ok(_) = mist.send_text_frame(conn, <<text:utf8>>)
      actor.Continue(state)
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
    |> response.set_body(mist.Bytes(bit_builder.from_bit_string(req.body)))
    |> response.set_header("content-type", content_type)
  })
  |> result.lazy_unwrap(fn() {
    response.new(400)
    |> response.set_body(mist.Bytes(bit_builder.new()))
  })
}

fn serve_chunk(_request: Request(Connection)) -> Response(ResponseData) {
  let iter =
    ["one", "two", "three"]
    |> iterator.from_list
    |> iterator.map(bit_builder.from_string)

  response.new(200)
  |> response.set_body(mist.Chunked(iter))
  |> response.set_header("content-type", "text/plain")
}

fn serve_file(
  _req: Request(Connection),
  path: List(String),
) -> Response(ResponseData) {
  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bit_builder.new()))

  let file_path =
    path
    |> string.join("/")
    |> bit_string.from_string

  // Omitting validation for brevity
  let file_descriptor = file.open(file_path)
  let file_size = file.size(file_path)

  case file_descriptor {
    Ok(file) -> {
      let content_type = guess_content_type(file_path)
      response.new(200)
      |> response.set_body(mist.File(file, content_type, 0, file_size))
    }
    _ -> not_found
  }
}

fn handle_form(req: Request(Connection)) -> Response(ResponseData) {
  let _req = mist.read_body(req, 1024 * 1024 * 30)
  response.new(200)
  |> response.set_body(mist.Bytes(bit_builder.new()))
}

fn guess_content_type(_path: BitString) -> String {
  "application/octet-stream"
}
```
