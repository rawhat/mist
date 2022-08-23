import glisten
import glisten/acceptor
import glisten/handler.{LoopFn}
import glisten/socket.{Ssl, Tcp}
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
  |> handler.with(Tcp, max_body_limit)
  |> acceptor.new_pool_with_data(handler.new_state())
  |> glisten.serve(port, _)
}

/// Similar setup and behavior to `run_service`, but instead takes in the SSL
/// certificate/key and serves over HTTPS.
pub fn run_service_ssl(
  port port: Int,
  certfile certfile: String,
  keyfile keyfile: String,
  handler handler: handler.Handler,
  max_body_limit max_body_limit: Int,
) -> Result(Nil, glisten.StartError) {
  handler
  |> handler.with(Ssl, max_body_limit)
  |> acceptor.new_pool_with_data(handler.new_state())
  |> glisten.serve_ssl(
    port: port,
    certfile: certfile,
    keyfile: keyfile,
    with_pool: _,
  )
}

/// Slightly more flexible alternative to `run_service`. This allows hooking
/// into the `mist/http.{handler_func}` method. Note that the request body
/// will not be automatically read. You will need to call `http.read_body`.
pub fn serve(
  port: Int,
  handler: LoopFn(State),
) -> Result(Nil, glisten.StartError) {
  handler
  |> acceptor.new_pool_with_data(handler.new_state())
  |> glisten.serve(port, _)
}

/// Similar to the `run_service` method, `serve` also has a similar SSL method.
pub fn serve_ssl(
  port: Int,
  certfile certfile: String,
  keyfile keyfile: String,
  handler: LoopFn(State),
) -> Result(Nil, glisten.StartError) {
  handler
  |> acceptor.new_pool_with_data(handler.new_state())
  |> glisten.serve_ssl(
    port: port,
    certfile: certfile,
    keyfile: keyfile,
    with_pool: _,
  )
}
