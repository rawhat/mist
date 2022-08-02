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
  erlang.sleep_forever()
}
```

Maybe you also want to work with websockets.  Maybe those should only be
upgradable at a certain endpoint.  For that, you can use `http_func`. The
websocket methods help you build a handler with connect/disconnect handlers.
You can use these to, for example, track connected clients.  For example:

```gleam
pub fn main() {
  assert Ok(_) =
    serve(
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
            // NOTE: This is response from `mist/http`
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
  erlang.sleep_forever()
}
```

There is some initial support for sending files as well:

```gleam
import mist/file
import mist/http.{BitBuilderBody, FileBody, Response} as mhttp
// ...

pub fn main() {
  assert Ok(_) =
    serve(
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
  erlang.sleep_forever()
}
```

If you need something a little more complex or custom, you can always use the
helpers exported by the various `glisten`/`mist` modules.

## Benchmarks

These are currently located [here](https://github.com/rawhat/http-benchmarks)
