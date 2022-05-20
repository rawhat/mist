import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Option, Some}
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import glisten/tcp
import mist/http
import mist/websocket.{TextFrame, TextMessage}

pub type Route(state) {
  Route(path: String, handler: HttpHandler)
}

pub type Router {
  Router(routes: List(String))
}

pub type HttpHandler {
  Http1(
    path: List(String),
    handler: http.Handler,
  )
  Websocket(
    path: List(String),
    handler: websocket.Handler,
  )
}

pub type State {
  State(
    upgraded_handler: Option(
      fn(websocket.Message, tcp.Socket) -> Result(Nil, Nil),
    ),
  )
}

pub fn new_state() -> State {
  State(upgraded_handler: None)
}

pub fn validate_path(path: List(String), req: List(String)) -> Result(Nil, Nil) {
  case path, req {
    ["*", ..], _ -> Ok(Nil)
    [expected], [actual] if expected == actual -> Ok(Nil)
    [expected, ..path], [actual, ..rest] if expected == actual ->
      validate_path(path, rest)
    _, _ -> Error(Nil)
  }
}

pub fn new(routes: List(HttpHandler)) -> tcp.LoopFn(State) {
  tcp.handler(fn(msg, ws_state: #(tcp.Socket, State)) {
    let #(socket, state) = ws_state

    case state.upgraded_handler {
      Some(handler) ->
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
      None -> {
        assert Ok(req) = http.parse_request(msg)
        let matching_handler =
          routes
          |> list.find_map(fn(route) {
            case route {
              Http1(path, ..) | Websocket(path, ..) ->
                req
                |> request.path_segments
                |> validate_path(path, _)
                |> result.replace(route)
              _ -> Error(Nil)
            }
          })
        case matching_handler {
          Ok(Websocket(_path, handler)) ->
            req
            |> websocket.upgrade(socket, _)
            |> result.replace(actor.Continue(#(socket, State(Some(handler)))))
            |> result.replace_error(actor.Stop(process.Normal))
            |> result.unwrap_both
          Ok(Http1(_path, handler)) ->
            req
            |> handler
            |> http.to_bit_builder
            |> tcp.send(socket, _)
            |> result.replace_error(Nil)
            |> result.replace(actor.Stop(process.Normal))
            |> result.unwrap(actor.Stop(process.Normal))
          Error(_) ->
            response.new(404)
            |> response.set_body(<<"":utf8>>)
            |> http.to_bit_builder
            |> tcp.send(socket, _)
            |> result.replace_error(Nil)
            |> result.replace(actor.Stop(process.Normal))
            |> result.unwrap(actor.Stop(process.Normal))
        }
      }
    }
  })
}

pub fn example_router() {
  new([
    Http1(
      ["home"],
      fn(_req) {
        response.new(200)
        |> response.set_body(<<"sup home boy":utf8>>)
      },
    ),
    Websocket(["echo", "test"], websocket.echo_handler),
    Http1(
      ["*"],
      fn(_req) {
        response.new(200)
        |> response.set_body(<<"Hello, world!":utf8>>)
      },
    ),
  ])
}
