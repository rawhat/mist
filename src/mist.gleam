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
