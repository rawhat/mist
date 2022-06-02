# mist

A (hopefully) nice, basic Gleam web server

## Installation

This package can be added to your Gleam project:

```sh
gleam add mist
```

and its documentation can be found at <https://hexdocs.pm/mist>.

## Usage

Right now there are 2 options.  Let's say you want a "simple" HTTP server that
you can customize to your heart's content.  In that case, you want:

```gleam
pub fn main() {
  assert Ok(_) = mist.serve(
    8080,
    http.handler(fn(req: Request(BitString)) {
      response.new(200)
      |> response.set_body(bit_builder.from_bit_string(<<"hello, world!":utf8>>))
    })
  )
  erlang.sleep_forever()
}
```

Maybe you also want to work with websockets.  Maybe those should only be
upgradable at a certain endpoint.  For that, you can use `http_func`.
For example:

```gleam
pub fn main() {
  assert Ok(_) = serve(
    8080,
    http.handler_func(fn(req: Request(BitString)) {
      case request.path_segments(req) {
        ["echo", "test"] -> Upgrade(websocket.echo_handler)
        ["home"] ->
          response.new(200)
          |> response.set_body(bit_builder.from_bit_string(<<"sup home boy":utf8>>))
          |> HttpResponse
        _ ->
          response.new(200)
          |> response.set_body(bit_builder.from_bit_string(<<"Hello, world!":utf8>>))
          |> HttpResponse
      }
    })
  )
  erlang.sleep_forever()
}
```

If you need something a little more complex or custom, you can always use the
helpers exported by the various `glisten`/`mist` modules.

## Benchmarks

These are currently located [here](https://github.com/rawhat/http-benchmarks)
