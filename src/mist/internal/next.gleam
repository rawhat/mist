import gleam/erlang/process.{type Selector}
import gleam/option.{type Option}

pub type Next(state, message) {
  Continue(state: state, selector: Option(Selector(message)))
  NormalStop
  AbnormalStop(reason: String)
}
