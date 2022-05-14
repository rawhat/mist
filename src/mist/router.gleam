import gleam/bit_string
import gleam/http/request
import gleam/http/response
import mist/http.{HttpHandler}
import mist/websocket

pub type Route(state) {
  Route(path: String, handler: HttpHandler(state))
}

pub type Router {
  Router(routes: List(String))
}

pub fn validate_path(path: List(String), req: List(String)) -> Result(Nil, Nil) {
  case path, req {
    [expected], [actual] if expected == actual -> Ok(Nil)
    [expected, ..path], [actual, ..rest] if expected == actual -> validate_path(path, rest)
    _, _ -> Error(Nil)
  }
}

// NOTE:  these functions should instead return Result(Response(BitString), Nil)
// or something... and then the router will try all of them and take the first
// Ok or _THEN_ 404... which would allow a fallback handler too

pub fn http_handler(
  path: List(String),
  handler func: http.Handler,
) -> http.HttpHandler(Nil) {
  http.handler(fn(req) {
    case validate_path(path, request.path_segments(req)) {
      Ok(_) -> func(req)
      Error(_) ->
        response.new(404)
        |> response.set_body(bit_string.from_string(""))
    }
  })
}

pub fn ws_handler(
  path: String,
  handler func: websocket.Handler,
) -> http.HttpHandler(websocket.State) {
  // TODO:  maybe just move the handler in here somehow?  with some minor
  // modifications or something... and then just like change the case to be
  // something like... upgraded? send message through. validate path. valid?
  // attempt upgrade. if upgraded, update state and continue. if not valid,
  // error out
  todo
}

pub fn example_router() {
  new([
    http_handler([], fn(req) {
      todo
    }),
    http_handler(["home"], fn(req) {
      todo
    }),
    ws_handler(["echo", "test"], fn(message) {
      todo
    })
  ])
}
