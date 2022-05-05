import gleam/bit_string
import gleam/bit_string
import gleam/erlang/charlist
import gleam/otp/actor
import gleam/otp/process
import mist/http.{http_response}
import mist/glisten/glisten/tcp.{
  HandlerMessage, LoopFn, Socket, send,
}

/// Just your standard `hello_world` handler
pub fn hello_world(_msg: HandlerMessage, sock: Socket) -> actor.Next(Socket) {
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

/// Re-exported from `glisten`
pub fn listen(
  port: Int,
  options: List(tcp.TcpOption),
) -> Result(tcp.ListenSocket, tcp.SocketReason) {
  tcp.listen(port, options)
}

/// Re-exported from `glisten`
pub fn start_acceptor_pool(
  listener_socket: tcp.ListenSocket,
  handler: LoopFn(data),
  initial_state: data,
  pool_count: Int,
) -> Result(Nil, Nil) {
  tcp.start_acceptor_pool(listener_socket, handler, initial_state, pool_count)
}
