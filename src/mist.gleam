import gleam/dynamic.{Dynamic}
import gleam/erlang
import gleam/http/response
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import mist/http.{http_response}
import mist/router
import mist/tcp.{
  Closed, HandlerMessage, Socket, Timeout, send, start_acceptor_pool,
}
import mist/websocket

/// Just your standard `hello_world` handler
pub fn hello_world(_msg: HandlerMessage, sock: Socket) -> actor.Next(Socket) {
  assert Ok(_resp) =
    200
    |> http_response(<<"hello, world!":utf8>>)
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
pub fn serve(
  port: Int,
  handler: tcp.LoopFn(router.State),
) -> Result(Nil, StartError) {
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
      |> start_acceptor_pool(handler, router.new_state(), 10)
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
  let _ =
    router.new([
      router.ws_handler(
        ["/"],
        fn(msg, socket) {
          socket
          |> websocket.send(msg.data)
          |> result.replace_error(Nil)
        },
      ),
    ])
    |> serve(8080, _)

  erlang.sleep_forever()
}

pub fn echo_server() {
  assert Ok(_) =
    serve(
      8080,
      router.new([
        router.http_handler(
          ["*"],
          fn(req) {
            response.new(200)
            |> response.set_body(req.body)
          },
        ),
      ]),
    )

  erlang.sleep_forever()
}

pub fn main() {
  assert Ok(_) =
    router.example_router()
    |> serve(8080, _)

  erlang.sleep_forever()
}
