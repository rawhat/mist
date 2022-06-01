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
    http.handler(fn(_req) {
      response.new(200)
      // ...
    })
  )
  erlang.sleep_forever()
}
```

Maybe you also want to work with websockets.  Maybe those should only be
upgradable at a certain endpoint.  For that, you can use the router module.
For example:

```gleam
pub fn main() {
  let my_router =
    router.new([
      router.Http1(
        ["home"],
        fn(_req) {
          response.new(200)
          |> response.set_body(bit_builder.from_bit_string(<<"sup home boy":utf8>>))
        },
      ),
      router.Websocket(["echo", "test"], websocket.echo_handler),
      router.Http1(
        ["*"],
        fn(_req) {
          response.new(200)
          |> response.set_body(bit_builder.from_bit_string(<<"Hello, world!":utf8>>))
        },
      ),
    ])
  assert Ok(_) = serve(8080, my_router)
  erlang.sleep_forever()
}
```

If you need something a little more complex, you can always use the helpers
exported by the various `glisten`/`mist` modules.

#### HTTP Hello World
```gleam
pub fn main() {
  assert Ok(_) = glisten.serve(
    8080,
    http.handler(fn(_req) {
      response.new(200)
      |> response.set_body(bit_builder.from_bit_string(<<"hello, world!":utf8>>))
    }),
    None
  )
  erlang.sleep_forever()
}
```

#### Full HTTP echo handler
```gleam
pub fn main() {
  let service = fn(req: Request(BitString)) -> Response(BitBuilder) {
    response.new(200)
    |> response.set_body(bit_builder.from_bit_string(req.body))
  }
  assert Ok(_) = glisten.serve(
    8080,
    router.new([router.Http1(["*"], service)]),
    http.new_state(),
  )
  erlang.sleep_forever()
}
```

#### Websocket echo handler
```gleam
pub fn main() {
  assert Ok(_) = glisten.serve(
    8080,
    router.new([router.Websocket(["echo", "test"], websocket.echo_handler)]),
    http.new_state(),
  )
  erlang.sleep_forever()
}
```

## Benchmarks

These are currently located [here](https://github.com/rawhat/http-benchmarks)
