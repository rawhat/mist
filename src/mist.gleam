import glisten
import glisten/tcp
import mist/handler.{State}
import gleam/bit_builder
import gleam/bit_string
import gleam/erlang/process
import gleam/http/request.{Request}
import gleam/http/response
import gleam/int
import gleam/string
import mist/file
import mist/handler.{Response}
import mist/http.{BitBuilderBody, Body, FileBody}

/// Runs an HTTP Request->Response server at the given port, with your defined
/// handler. This will automatically read the full body contents up to the
/// specified `max_body_limit` in bytes. If you'd prefer to have finer-grain
/// control over this behavior, consider using `mist.serve`.
pub fn run_service(
  port: Int,
  handler: handler.Handler,
  max_body_limit max_body_limit: Int,
) -> Result(Nil, glisten.StartError) {
  handler
  |> handler.with(max_body_limit)
  |> tcp.acceptor_pool_with_data(handler.new_state())
  |> glisten.serve(port, _)
}

/// Slightly more flexible alternative to `run_service`. This allows hooking
/// into the `mist/http.{handler_func}` method. Note that the request body
/// will not be automatically read. You will need to call `http.read_body`.
pub fn serve(
  port: Int,
  handler: tcp.LoopFn(State),
) -> Result(Nil, glisten.StartError) {
  handler
  |> tcp.acceptor_pool_with_data(handler.new_state())
  |> glisten.serve(port, _)
}

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
  process.sleep_forever()
}
