# mist

[![Package Version](https://img.shields.io/hexpm/v/mist)](https://hex.pm/packages/mist)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/mist/)

## A glistening Gleam web server.

To follow along with the example below, you can create a new project and add the
dependencies as follows:

```sh
$ gleam new <your_project>
$ cd <your_project>
$ gleam add mist gleam_erlang gleam_http gleam_otp
```

The main entrypoints for your application are `mist.start_http` and
`mist.start_https`. The argument to these functions is generated from the
opaque `Builder` type. It can be constructed with the `mist.new` function, and
fed updated configuration options with the associated methods (demonstrated
in the examples below).

```gleam
import gleam/bytes_builder
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/iterator
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}

pub fn main() {
  // These values are for the Websocket process initialized below
  let selector = process.new_selector()
  let state = Nil

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_builder.new()))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(req) {
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
    |> mist.port(3000)
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
```

## Streaming request body

```
NOTE:  This is a new feature, and I may have made some mistakes.  Please let me
know if you run into anything :)
```

When handling file uploads or `multipart/form-data`, you probably don't want to
load the whole file into memory. Previously, the only options in `mist` were to
accept bodies up to `N` bytes, or read the entire body.

Now, there is a `mist.stream` function which takes a `Request(Connection)` that
gives you back a function to start reading chunks. This function will return:

```gleam
pub type Chunk {
  Chunk(data: BitString, consume: fn(Int) -> Chunk)
  Done
}
```

NOTE: You must only call this once on the `Request(Connection)`. Since it's
reading data from the socket, this is a mutable action. The name `consume` was
chosen to hopefully make that more clear.

### Example

```gleam
// Replacing the named function in the application example above
fn handle_form(req: Request(Connection)) -> Response(ResponseData) {
  let assert Ok(consume) = mist.stream(req)
  // NOTE:  This is a little misleading, since `Iterator`s can be replayed.
  // However, this will only be running this once.
  let content =
    iterator.unfold(
      consume,
      fn(consume) {
        // Reads up to 1024 bytes from the request
        let res = consume(1024)
        case res {
          // The error will not be bubbled up to the iterator here. If either
          // we've read all the body, or we see an error, the iterator finishes
          Ok(mist.Done) | Error(_) -> iterator.Done
          // We read some data. It may be less than the specific amount above if
          // we have consumed all of the body. You'll still need to call it
          // again to ensure, since with `chunked` encoding, we need to check
          // for the last chunk.
          Ok(mist.Chunk(data, consume)) -> {
            iterator.Next(bit_builder.from_bit_string(data), consume)
          }
        }
      },
    )
  // For fun, respond with `chunked` encoding of the same iterator
  response.new(200)
  |> response.set_body(mist.Chunked(content))
}
```
