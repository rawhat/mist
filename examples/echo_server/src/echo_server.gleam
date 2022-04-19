import mist.{make_handler}
import gleam/erlang
import gleam/http/request.{Request}
import gleam/http/response.{Response}

pub fn handler(req: Request(BitString)) -> Response(BitString) {
  response.new(200)
  |> response.set_body(req.body)
}

pub fn main() {
  assert Ok(socket) = mist.listen(8000, [])
  try _ = mist.start_acceptor_pool(socket, make_handler(handler), 10)

  Ok(erlang.sleep_forever())
}
