import gleam/bit_string
import gleam/erlang/charlist
import gleam/http/request
import gleam/http/response
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import mist/http
import mist/tcp
import mist/websocket.{TextFrame, TextMessage}

pub type HttpHandler {
  Http1Handler(
    path: List(String),
    fn(request.Request(BitString)) -> response.Response(BitString),
  )
  WebsocketHandler(
    path: List(String),
    fn(websocket.Message, tcp.Socket) -> Result(Nil, Nil),
  )
}

pub type Route(state) {
  Route(path: String, handler: HttpHandler)
}

pub type Router {
  Router(routes: List(String))
}

pub fn validate_path(path: List(String), req: List(String)) -> Result(Nil, Nil) {
  io.debug(#("validating", path, req))
  case path, req {
    ["*", ..], _ | ["*"], _ -> Ok(Nil)
    [expected], [actual] if expected == actual -> Ok(Nil)
    [expected, ..path], [actual, ..rest] if expected == actual ->
      validate_path(path, rest)
    _, _ -> Error(Nil)
  }
}

// NOTE:  these functions should instead return Result(Response(BitString), Nil)
// or something... and then the router will try all of them and take the first
// Ok or _THEN_ 404... which would allow a fallback handler too
// pub fn http_handler(
//   path: List(String),
//   handler: http.Handler,
// ) -> http.HttpHandler {
//   http.HttpHandler(
//     func: fn(msg, state) {
//       let #(socket, _state) = state
//
//       msg
//       |> http.from_charlist
//       |> result.map_error(http.InvalidRequest)
//       |> result.then(fn(req) {
//         req
//         |> request.path_segments
//         |> validate_path(path, _)
//         |> result.replace(req)
//         |> result.replace_error(http.NotFound)
//       })
//       |> result.map(handler)
//       |> result.replace_error()
//
//       |> result.map(http.to_string)
//       |> result.then(bit_string.to_string)
//       |> result.then(fn(bs) {
//         bs
//         |> bit_string.to_string
//         |> result.replace_error(http.SendFailure)
//       })
//       |> result.map(fn(resp) { tcp.send(socket, charlist.from_string(resp)) })
//       |> result.replace_error(http.SendFailure)
//     },
//     state: http.new_state(),
//   )
//   // http.HttpHandler(
//   //   func: fn(msg, state) {
//   //     case validate_path(path, )
//   //   },
//   //   state: handler.state,
//   // )
//   //
//   // http.handler(fn(req) {
//   //   case validate_path(path, request.path_segments(req)) {
//   //     Ok(_) -> func(req)
//   //     Error(_) ->
//   //       response.new(404)
//   //       |> response.set_body(bit_string.from_string(""))
//   //   }
//   // })
// }
// pub fn ws_handler(
//   path: List(String),
//   handler func: websocket.Handler,
// ) -> http.HttpHandler {
//   HttpHandler(
//     func: fn(msg, state) {
//       let #(socket, http.State(upgraded) as ws_state) = state
//       case msg, upgraded {
//         data, False ->
//           data
//           |> http.from_charlist
//           |> result.replace_error(Nil)
//           |> result.then(fn(req) {
//             case validate_path(path, request.path_segments(req)) {
//               Ok(Nil) -> Ok(req)
//               Error(_) -> Error(Nil)
//             }
//           })
//           |> result.map(websocket.upgrade(socket, _))
//           |> result.replace(actor.Continue(#(socket, http.State(True))))
//           |> result.unwrap(actor.Stop(process.Normal))
//           |> Ok
//         data, True ->
//           case websocket.frame_from_message(data) {
//             Ok(TextFrame(payload: payload, ..)) ->
//               payload
//               |> TextMessage
//               |> func(socket, ws_state)
//               |> actor.Continue
//               |> Ok
//             Error(_) ->
//               // TODO:  not normal
//               actor.Stop(process.Normal)
//               |> Ok
//           }
//       }
//     },
//     state: http.State(False),
//   )
// }
pub fn new(routes: List(HttpHandler)) -> tcp.LoopFn(http.State) {
  tcp.handler(fn(msg, state) {
    let #(socket, state) = state

    routes
    |> list.find_map(fn(route) {
      case route, state {
        Http1Handler(path, handler), _ -> {
            msg
            |> http.from_charlist
            |> result.map_error(http.InvalidRequest)
            |> result.then(fn(req) {
              req
              |> request.path_segments
              |> validate_path(path, _)
              |> result.replace(req)
              |> result.replace_error(http.NotFound)
            })
            |> result.map(handler)
            |> result.map_error(fn(err) {
              case err {
                http.InvalidRequest(_) -> response.new(400)
                http.NotFound -> response.new(404)
              }
              |> response.set_body(bit_string.from_string(""))
            })
            |> result.unwrap_both
            |> http.to_string
            |> bit_string.to_string
            |> fn(resp) {
              assert Ok(resp) = resp
              resp
            }
            |> charlist.from_string
            |> tcp.send(socket, _)
            |> result.replace(actor.Stop(process.Normal))
            |> result.replace_error(actor.Stop(process.Normal))
        }
        WebsocketHandler(path, handler), http.State(False) ->
            msg
            |> http.from_charlist
            |> result.map_error(http.InvalidRequest)
            |> result.then(fn(req) {
              req
              |> request.path_segments
              |> validate_path(path, _)
              |> result.replace(req)
              |> result.replace_error(http.NotFound)
            })
            |> result.map(websocket.upgrade(socket, _))
            |> result.replace(actor.Continue(#(socket, http.State(True))))
            |> result.replace_error(actor.Stop(process.Normal))
            |> result.unwrap_both
        // We are assuming that if the handler is receiving this message, it has
        // already gone through the upgrade process successfully!
        WebsocketHandler(_path, handler), http.State(True) -> {
          case websocket.frame_from_message(msg) {
            Ok(TextFrame(payload: payload, ..)) ->
              payload
              |> TextMessage
              |> handler(socket)
              |> result.replace(actor.Continue(#(socket, state)))
              |> result.replace_error(actor.Stop(process.Normal))
              |> result.unwrap_both
            Error(_) ->
              // TODO:  not normal
              actor.Stop(process.Normal)
          }
        }
      }
    })
    |> result.unwrap(actor.Stop(process.Normal))
  })
}

pub fn example_router() {
  new([
    http_handler(
      ["home"],
      fn(_req) {
        response.new(200)
        |> response.set_body(bit_string.from_string("sup home boy"))
      },
    ),
    ws_handler(["echo", "test"], websocket.echo_handler),
    http_handler(
      ["*"],
      fn(_req) {
        response.new(200)
        |> response.set_body(bit_string.from_string("Hello, world!"))
      },
    ),
  ])
}
