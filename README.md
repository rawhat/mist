# mist

A (hopefully) nice, pure Gleam web server

## Installation

This package can be added to your Gleam project:

```sh
gleam add mist
```

and its documentation can be found at <https://hexdocs.pm/mist>.

## Usage

Right now there are a few options.  Let's say you want a "simple" HTTP server
that you can customize to your heart's content.  In that case, you want:

```gleam
import mist
import gleam/bit_builder
import gleam/erlang/process
import gleam/http/response

pub fn main() {
  assert Ok(_) =
    mist.run_service(
      8080,
      fn(_req) {
        response.new(200)
        |> response.set_body(bit_builder.from_bit_string(<<
          "hello, world!":utf8,
        >>))
      },
      max_body_limit: 4_000_000
    )
  process.sleep_forever()
}
```

Maybe you also want to work with websockets.  Maybe those should only be
upgradable at a certain endpoint.  For that, you can use `handler.with_func`.
The websocket methods help you build a handler with connect/disconnect handlers.
You can use these to, for example, track connected clients.  For example:

```gleam
import mist
import gleam/bit_builder
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/result
import mist/handler.{Response, Upgrade}
import mist/http.{BitBuilderBody}
import mist/websocket

pub fn main() {
  assert Ok(_) =
    mist.serve(
      8080,
      handler.with_func(fn(req) {
        case req.method, request.path_segments(req) {
          Get, ["echo", "test"] ->
            websocket.echo_handler
            |> websocket.with_handler
            |> Upgrade
          Post, ["echo", "body"] ->
            req
            |> http.read_body
            |> result.map(fn(req) {
              response.new(200)
              |> response.set_body(BitBuilderBody(bit_builder.from_bit_string(
                req.body,
              )))
              |> response.prepend_header(
                "content-type",
                request.get_header(req, "content-type")
                |> result.unwrap("application/octet-stream"),
              )
            })
            |> result.unwrap(
              response.new(400)
              |> response.set_body(BitBuilderBody(bit_builder.new())),
            )
            |> Response
          Get, ["home"] ->
            response.new(200)
            |> response.set_body(BitBuilderBody(bit_builder.from_bit_string(<<
              "sup home boy":utf8,
            >>)))
            |> Response
          _, _ ->
            response.new(200)
            |> response.set_body(BitBuilderBody(bit_builder.from_bit_string(<<
              "Hello, world!":utf8,
            >>)))
            |> Response
        }
      }),
    )
  process.sleep_forever()
}
```

You might also want to use SSL.  You can do that with the following options.

With `run_service_ssl`:

```gleam
import mist
import gleam/bit_builder
import gleam/erlang/process
import gleam/http/response

pub fn main() {
  assert Ok(_) =
    mist.run_service_ssl(
      port: 8080,
      certfile: "/path/to/server.crt",
      keyfile: "/path/to/server.key",
      handler: fn(_req) {
        response.new(200)
        |> response.set_body(bit_builder.from_bit_string(<<
          "hello, world!":utf8,
        >>))
      },
      max_body_limit: 4_000_000
    )
  process.sleep_forever()
}
```

With `serve_ssl`:

```gleam
pub fn main() {
  assert Ok(_) =
    mist.serve_ssl(
      port: 8080,
      certfile: "...",
      keyfile: "...",
      handler.with_func(fn(req) {
        todo
      }
    )
  // ...
}
```

There is support for sending files as well. This uses the `file:sendfile` erlang
method under the hood.

```gleam
import gleam/bit_builder
import gleam/bit_string
import gleam/erlang/process
import gleam/http/request.{Request}
import gleam/http/response
import gleam/int
import gleam/string
import mist
import mist/file
import mist/handler.{Response}
import mist/http.{BitBuilderBody, Body, FileBody}

pub fn main() {
  assert Ok(_) =
    mist.serve(
      8080,
      handler.with_func(fn(req: Request(Body)) {
        case request.path_segments(req) {
          ["static", ..path] -> {
            // verify, validate, etc
            let file_path =
              path
              |> string.join("/")
              |> string.append("/", _)
              |> bit_string.from_string
            let size = file.size(file_path)
            assert Ok(fd) = file.open(file_path)
            response.new(200)
            |> response.set_body(FileBody(fd, int.to_string(size), 0, size))
            |> Response
          }
          _ ->
            response.new(404)
            |> response.set_body(BitBuilderBody(bit_builder.new()))
            |> Response
        }
      }),
    )
  process.sleep_forever()
}
```

You can return chunked responses using the `mist/http.{Chunked}` response body
type. This takes an `Iterator(BitBuilder)` and handles sending the initial
response, and subsequent chunks in the proper format as they are emitted from
the iterator.

If you need something a little more complex or custom, you can always use the
helpers exported by the various `glisten`/`mist` modules.

## Benchmarks

These are currently located [here](https://github.com/rawhat/http-benchmarks)
