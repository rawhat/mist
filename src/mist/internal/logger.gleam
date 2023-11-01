import gleam/erlang/charlist.{type Charlist}

@external(erlang, "logger", "error")
fn log_error(format format: Charlist, data data: any) -> Nil

pub fn error(data: any) -> Nil {
  log_error(charlist.from_string("~tp"), [data])
}
