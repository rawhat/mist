import birl
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/function
import gleam/otp/actor
import gleam/result
import logging

pub type ClockMessage {
  SetTime
}

type ClockTable {
  MistClock
}

type TableKey {
  DateHeader
}

pub type EtsOpts {
  Set
  Protected
  NamedTable
  ReadConcurrency(Bool)
}

pub fn start(_type, _args) -> Result(Pid, actor.StartError) {
  actor.start_spec(
    actor.Spec(
      init: fn() {
        let subj = process.new_subject()
        let selector =
          process.new_selector()
          |> process.selecting(subj, function.identity)
        ets_new(MistClock, [Set, Protected, NamedTable, ReadConcurrency(True)])
        process.send(subj, SetTime)
        actor.Ready(subj, selector)
      },
      init_timeout: 500,
      loop: fn(msg, state) {
        case msg {
          SetTime -> {
            ets_insert(MistClock, #(DateHeader, date()))
            process.send_after(state, 1000, SetTime)
            actor.continue(state)
          }
        }
      },
    ),
  )
  |> result.map(process.subject_owner)
}

pub fn stop(_state) {
  atom.create_from_string("ok")
}

pub fn get_date() -> String {
  case ets_lookup_element(MistClock, DateHeader, 2) {
    Ok(value) -> value
    _ -> {
      logging.log(logging.Warning, "Failed to lookup date, re-calculating")
      date()
    }
  }
}

fn date() -> String {
  birl.now()
  |> birl.to_http
}

@external(erlang, "ets", "new")
fn ets_new(table: ClockTable, opts: List(EtsOpts)) -> ClockTable

@external(erlang, "ets", "insert")
fn ets_insert(table: ClockTable, value: #(TableKey, String)) -> Nil

@external(erlang, "mist_ffi", "ets_lookup_element")
fn ets_lookup_element(
  table: ClockTable,
  key: TableKey,
  position: Int,
) -> Result(String, Nil)
