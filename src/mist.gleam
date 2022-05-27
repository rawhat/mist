import gleam/option.{None, Option}
import gleam/otp/process
import glisten
import glisten/tcp
import gleam/http
import gleam/http/request.{Request}
import gleam/http/response
import mist/http as mhttp
import gleam/erlang

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
    |> response.set_body(<<>>)

  let not_found =
    response.new(404)
    |> response.set_body(<<>>)

  assert Ok(_) =
    serve(
      8080,
      mhttp.handler(fn(req: Request(BitString)) {
        case req.method, request.path_segments(req) {
          http.Get, [] -> empty_response
          http.Get, ["user", id] ->
            response.new(200)
            |> response.set_body(<<id:utf8>>)
          http.Post, ["user"] ->
            response.new(200)
            |> response.set_body(req.body)
          _, _ -> not_found
        }
      }),
    )
  erlang.sleep_forever()
}
