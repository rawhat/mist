# mist

A (hopefully) nice, basic Gleam web server

## Installation

This package can be added to your Gleam project:

```sh
gleam add mist
```

and its documentation can be found at <https://hexdocs.pm/mist>.

#### HTTP Hello World
```gleam
pub fn ok(_msg: HandlerMessage, sock: Socket) -> actor.Next(Socket) {
  assert Ok(resp) =
    "hello, world!"
    |> bit_string.from_string
    |> http_response(200, _)
    |> bit_string.to_string

  resp
  |> charlist.from_string
  |> send(sock, _)

  actor.Stop(process.Normal)
}
```

#### Full HTTP echo handler
```gleam
pub fn main() {
  let service = fn(req: Request(BitString)) -> Response(BitString) {
    response.new(200)
    |> response.set_body(req.body)
  }

  assert Ok(_resp) = serve(8080, http.handler(service))
  erlang.sleep_forever()

}
```

#### Websocket echo handler
```gleam
pub fn echo_handler(
  msg: Message,
  socket: Socket,
  state: State,
) -> #(Socket, State) {
  assert Ok(_resp) = ws_send(socket, msg.data)

  #(socket, state)
}

pub fn main() {
  assert Ok(_) = serve(8080, websocket.handler(echo_handler))
  erlang.sleep_forever()
}
```

## Notes

This is still very rough.  There are no tests, and as noted above you can't just
send where you implement it.

In some [not-very-scientific benchmarking](https://gist.github.com/rawhat/11ab57ef8dde4170304adc01c8c05a99), it seemed to do roughly as well as
ThousandIsland.  I am just using that as a reference point, certainly not trying
to draw any comparisons any time soon!
