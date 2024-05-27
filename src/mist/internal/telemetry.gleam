import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/result
import gleam/string
import logging

pub type Event {
  Start
  Stop

  Mist

  ParseRequest
  ParseRequest2

  DecodePacket
  ConvertPath
  ParseMethod
  ParseHeaders
  ParseRest
  ParsePath
  ParseTransport
  ParseHost
  ParsePort
  BuildRequest
  ReadData

  Http1Handler
  HttpUpgrade
  Http2Handler
}

pub const events = [
  [Mist, ParseRequest, Stop], [Mist, ParseRequest2, Stop],
  [Mist, Http1Handler, Stop], [Mist, HttpUpgrade, Stop],
  [Mist, Http2Handler, Stop], [Mist, DecodePacket, Stop],
  [Mist, ConvertPath, Stop], [Mist, ParseMethod, Stop],
  [Mist, ParseHeaders, Stop], [Mist, ParseRest, Stop], [Mist, ParsePath, Stop],
  [Mist, ParseTransport, Stop], [Mist, ParseHost, Stop], [Mist, ParsePort, Stop],
  [Mist, BuildRequest, Stop], [Mist, ReadData, Stop],
]

type TimeUnit {
  Native
  Microsecond
}

@external(erlang, "erlang", "convert_time_unit")
fn convert_time_unit(
  time: Int,
  from from_unit: TimeUnit,
  to to_unit: TimeUnit,
) -> Int

pub fn log(
  path: List(Event),
  measurements: Dict(Atom, Dynamic),
  _metadata: Dict(String, Dynamic),
  _config: List(config),
) -> Nil {
  let duration_string =
    dict.get(measurements, atom.create_from_string("duration"))
    |> result.then(fn(val) { result.nil_error(dynamic.int(val)) })
    |> result.map(convert_time_unit(_, Native, Microsecond))
    |> result.map(fn(time) { " duration: " <> int.to_string(time) <> "μs, " })
    |> result.unwrap("")

  logging.log(logging.Debug, string.inspect(path) <> duration_string)
  // <> " metadata: "
  // <> string.inspect(metadata),
}

pub fn span(
  path: List(Event),
  metadata: Dict(String, Dynamic),
  wrapping: fn() -> return,
) -> return {
  use <- do_span(path, metadata)
  let res = wrapping()
  #(res, dict.new())
}

@external(erlang, "telemetry", "span")
fn do_span(
  path: List(Event),
  metadata: Dict(String, Dynamic),
  wrapping: fn() -> #(return, Dict(String, Dynamic)),
) -> return

pub fn attach_many(
  id: String,
  path: List(List(Event)),
  handler: fn(
    List(Event),
    Dict(Atom, Dynamic),
    Dict(String, Dynamic),
    List(config),
  ) ->
    Nil,
) -> Nil {
  do_attach_many(id, path, handler, Nil)
}

@external(erlang, "telemetry", "attach_many")
fn do_attach_many(
  id: String,
  path: List(List(Event)),
  handler: fn(
    List(Event),
    Dict(Atom, Dynamic),
    Dict(String, Dynamic),
    List(config),
  ) ->
    Nil,
  config: Nil,
) -> Nil

@external(erlang, "telemetry", "attach")
pub fn attach(
  id: String,
  event: List(Event),
  handler: fn(
    List(Event),
    Dict(Atom, Dynamic),
    Dict(String, Dynamic),
    List(config),
  ) ->
    Nil,
  config: Nil,
) -> Nil

pub fn configure_logger() {
  attach_many("mist-logger", events, log)
}
