import gleam/bit_string
import gleam/bit_string
import gleam/dynamic.{Dynamic}
import gleam/erlang
import gleam/erlang/charlist
import gleam/http/request.{Request}
import gleam/http/response.{Response}
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import mist/http.{HttpHandler, http_response}
import mist/tcp.{
  Closed, HandlerMessage, Socket, Timeout, send, start_acceptor_pool,
}
import mist/websocket.{echo_handler}

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

/// Reasons that `serve` might fail
pub type StartError {
  ListenerClosed
  ListenerTimeout
  AcceptorTimeout
  AcceptorFailed(process.ExitReason)
  AcceptorCrashed(Dynamic)
}

/// Sets up a TCP server listener at the provided port. Also takes the
/// HttpHandler, which holds the handler function.  There are currently two
/// options for ease of use: `http.handler` and `ws.handler`.
pub fn serve(port: Int, handler: HttpHandler(data)) -> Result(Nil, StartError) {
  try _ =
    port
    |> tcp.listen([])
    |> result.map_error(fn(err) {
      case err {
        Closed -> ListenerClosed
        Timeout -> ListenerTimeout
      }
    })
    |> result.then(fn(socket) {
      socket
      |> start_acceptor_pool(handler.func, handler.state, 10)
      |> result.map_error(fn(err) {
        case err {
          actor.InitTimeout -> AcceptorTimeout
          actor.InitFailed(reason) -> AcceptorFailed(reason)
          actor.InitCrashed(reason) -> AcceptorCrashed(reason)
        }
      })
    })

  Ok(Nil)
}

pub fn echo_ws_server() {
  assert Ok(_) = serve(8080, websocket.handler(echo_handler))
  erlang.sleep_forever()
}

pub fn echo_server() {
  let handler = fn(req: Request(BitString)) -> Response(BitString) {
    response.new(200)
    |> response.set_body(req.body)
  }

  assert Ok(_) = serve(8080, http.handler(handler))
  erlang.sleep_forever()
}
