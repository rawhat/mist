import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import logging
import mist

pub fn main() {
  logging.configure()
  logging.set_level(logging.Debug)

  let assert Ok(_server) =
    fn(_req) {
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
    |> mist.new()
    // |> mist.bind("0.0.0.0")
    |> mist.with_ipv6()
    |> mist.start_https(certfile: "localhost.crt", keyfile: "localhost.key")

  process.sleep_forever()
}
