import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/otp/actor
import gleam/result
import gleam/string
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
  actor.new_with_initialiser(500, fn(subject) {
    ets_new(MistClock, [Set, Protected, NamedTable, ReadConcurrency(True)])
    process.send(subject, SetTime)
    subject
    |> actor.initialised
    |> actor.selecting(process.new_selector() |> process.select(subject))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, msg) {
    case msg {
      SetTime -> {
        ets_insert(MistClock, #(DateHeader, date()))
        process.send_after(state, 1000, SetTime)
        actor.continue(state)
      }
    }
  })
  |> actor.start
  |> result.map(fn(start) {
    // NOTE:  This process is explicitly _not_ started with a name, so we can
    // safely assert here.
    let assert Ok(pid) = process.subject_owner(start.data)
    pid
  })
}

pub fn stop(_state) {
  atom.create("ok")
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

/// Returns today's date in a format suitable to be used as an http date header
/// (see here: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Date).
///
fn date() -> String {
  let #(weekday, #(year, month, day), #(hour, minute, second)) = now()

  let weekday = weekday_to_short_string(weekday)
  let year = int.to_string(year) |> string.pad_start(to: 4, with: "0")
  let month = month_to_short_string(month)
  let day = int.to_string(day) |> string.pad_start(to: 2, with: "0")
  let hour = int.to_string(hour) |> string.pad_start(to: 2, with: "0")
  let minute = int.to_string(minute) |> string.pad_start(to: 2, with: "0")
  let second = int.to_string(second) |> string.pad_start(to: 2, with: "0")

  { weekday <> ", " }
  <> { day <> " " <> month <> " " <> year <> " " }
  <> { hour <> ":" <> minute <> ":" <> second <> " GMT" }
}

fn weekday_to_short_string(weekday: Int) -> String {
  case weekday {
    1 -> "Mon"
    2 -> "Tue"
    3 -> "Wed"
    4 -> "Thu"
    5 -> "Fri"
    6 -> "Sat"
    7 -> "Sun"
    _ -> panic as "erlang weekday outside of 1-7 range"
  }
}

fn month_to_short_string(month: Int) -> String {
  case month {
    1 -> "Jan"
    2 -> "Feb"
    3 -> "Mar"
    4 -> "Apr"
    5 -> "May"
    6 -> "Jun"
    7 -> "Jul"
    8 -> "Aug"
    9 -> "Sep"
    10 -> "Oct"
    11 -> "Nov"
    12 -> "Dec"
    _ -> panic as "erlang month outside of 1-12 range"
  }
}

@external(erlang, "mist_ffi", "now")
fn now() -> #(Int, #(Int, Int, Int), #(Int, Int, Int))

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
