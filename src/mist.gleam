import glisten
import glisten/tcp
import mist/handler.{State}

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
