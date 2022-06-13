import glisten
import glisten/tcp
import mist/http.{State} as mhttp

/// Runs an HTTP Request->Response server at the given port, with your defined
/// handler.
pub fn run_service(
  port: Int,
  handler: mhttp.Handler,
) -> Result(Nil, glisten.StartError) {
  handler
  |> mhttp.handler
  |> tcp.acceptor_pool_with_data(mhttp.new_state())
  |> glisten.serve(port, _)
}

/// Slightly more flexible alternative to `run_service`. This allows hooking
/// into the `mist/http.{handler_func}` method.
pub fn serve(
  port: Int,
  handler: tcp.LoopFn(State),
) -> Result(Nil, glisten.StartError) {
  handler
  |> tcp.acceptor_pool_with_data(mhttp.new_state())
  |> glisten.serve(port, _)
}

import gleam/bit_builder
import gleam/erlang
import gleam/http/request.{Request}
import gleam/http/response
import gleam/io
import gleam/otp/process.{Sender}
import mist/http.{BitBuilderBody, Response, Upgrade}
import mist/websocket

fn on_init(sender: Sender(a)) -> Nil {
  io.debug(#("we got a ws connection", sender))
  Nil
}

pub fn main() {
  assert Ok(_) =
    serve(
      8080,
      http.handler_func(fn(req: Request(BitString)) {
        case request.path_segments(req) {
          ["echo", "test"] ->
            websocket.echo_handler
            |> websocket.with_handler
            |> websocket.on_init(on_init)
            |> Upgrade
          ["home"] ->
            response.new(200)
            |> response.set_body(BitBuilderBody(bit_builder.from_bit_string(<<
              "sup home boy":utf8,
            >>)))
            // NOTE: This is response from `mist/http`
            |> Response
          _ ->
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
