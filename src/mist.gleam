import gleam/option.{None, Option}
import gleam/otp/process
import glisten
import glisten/tcp
import gleam/bit_builder
import gleam/erlang
import gleam/http/request.{Request}
import gleam/http/response
import gleam/http
import mist/http as mhttp

/// Helper that wraps the `glisten.serve` with no state.  If you want to just
/// write HTTP handler(s), this is what you want
pub fn serve(
  port: Int,
  handler: tcp.LoopFn(Option(process.Timer)),
) -> Result(Nil, glisten.StartError) {
  glisten.serve(port, handler, None)
}

pub fn main() {
  let empty_response =
    response.new(200)
    |> response.set_body(bit_builder.new())

  let not_found =
    response.new(404)
    |> response.set_body(bit_builder.new())

  assert Ok(_) =
    serve(
      8080,
      mhttp.handler(fn(req: Request(BitString)) {
        case req.method, request.path_segments(req) {
          http.Get, [] -> empty_response
          http.Get, ["user", id] ->
            response.new(200)
            |> response.set_body(bit_builder.from_bit_string(<<id:utf8>>))
          http.Post, ["user"] ->
            response.new(200)
            |> response.set_body(bit_builder.from_bit_string(req.body))
          _, _ -> not_found
        }
      }),
    )
  erlang.sleep_forever()
}
