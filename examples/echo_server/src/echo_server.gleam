import dew.{make_handler}
import gleam/erlang
import gleam/http/request.{Request}
import gleam/http/response.{Response}

pub fn handler(req: Request(BitString)) -> Response(BitString) {
  response.new(200)
  |> response.set_body(req.body)
}

pub fn main() {
  assert Ok(socket) = dew.listen(8000, [])
  try _ = dew.start_acceptor_pool(socket, make_handler(handler), 10)

  Ok(erlang.sleep_forever())
}
