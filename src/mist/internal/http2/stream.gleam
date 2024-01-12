import gleam/dynamic
import gleam/erlang
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/http.{type Header} as ghttp
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/pair
import gleam/result
import gleam/string
import gleam/uri
import mist/internal/http.{
  type Connection, type Handler, type ResponseData, Connection, Stream,
}
import mist/internal/http2/frame.{type Frame, type StreamIdentifier}
import mist/internal/http2/flow_control

pub type Message {
  Ready
  Data(BitArray)
}

pub type StreamState {
  Open
  RemoteClosed
  LocalClosed
  Closed
}

pub type State {
  State(
    id: StreamIdentifier(Frame),
    state: StreamState,
    subject: Subject(Message),
    receive_window_size: Int,
    send_window_size: Int,
    pending_content_length: Option(Int),
  )
}

import gleam/io

pub fn new(
  _identifier: StreamIdentifier(any),
  handler: Handler,
  headers: List(Header),
  connection: Connection,
  send: fn(Response(ResponseData)) -> todo_resp,
) -> Result(Subject(Message), actor.StartError) {
  actor.start_spec(
    actor.Spec(
      init: fn() {
        let data_subj = process.new_subject()
        let data_selector =
          process.new_selector()
          |> process.selecting(data_subj, function.identity)
        actor.Ready(data_selector, data_selector)
      },
      init_timeout: 1000,
      loop: fn(msg, state) {
        case msg {
          Ready -> {
            io.println("hi we are ready")
            let content_length =
              headers
              |> list.key_find("content-length")
              |> result.then(int.parse)
              |> result.unwrap(0)
            let conn =
              Connection(
                ..connection,
                body: Stream(
                  selector: process.map_selector(state, fn(val) {
                    let assert Data(val) = val
                    val
                  }),
                  attempts: 0,
                  data: <<>>,
                  remaining: content_length,
                ),
              )

            request.new()
            |> request.set_body(conn)
            |> make_request(headers, _)
            |> result.map(handler)
            |> result.map(fn(resp) {
              io.println("sending response! " <> erlang.format(resp))
              send(resp)
              actor.continue(state)
            })
            |> result.map_error(fn(err) {
              actor.Stop(process.Abnormal(
                "Failed to respond to request: " <> erlang.format(err),
              ))
            })
            |> result.unwrap_both
          }
          _ -> {
            // TODO:  probably just discard this?
            actor.continue(state)
          }
        }
      },
    ),
  )
}

pub fn make_request(
  headers: List(Header),
  req: Request(Connection),
) -> Result(Request(Connection), Nil) {
  case headers {
    [] -> Ok(req)
    [#("method", method), ..rest] -> {
      method
      |> dynamic.from
      |> ghttp.method_from_dynamic
      |> result.replace_error(Nil)
      |> result.map(request.set_method(req, _))
      |> result.then(make_request(rest, _))
    }
    [#("scheme", scheme), ..rest] -> {
      scheme
      |> ghttp.scheme_from_string
      |> result.replace_error(Nil)
      |> result.map(request.set_scheme(req, _))
      |> result.then(make_request(rest, _))
    }
    // TODO
    [#("authority", _authority), ..rest] -> make_request(rest, req)
    [#("path", path), ..rest] -> {
      path
      |> string.split_once(on: "?")
      |> result.map(fn(split) {
        pair.map_second(split, fn(query) {
          query
          |> uri.parse_query
          |> result.map(Some)
          |> result.unwrap(None)
        })
      })
      |> result.unwrap(#(path, None))
      |> fn(tup: #(String, Option(List(#(String, String))))) {
        case tup.1 {
          Some(query) ->
            req
            |> request.set_path(tup.0)
            |> request.set_query(query)
          _ -> request.set_path(req, tup.0)
        }
        |> make_request(rest, _)
      }
    }
    [#(key, value), ..rest] ->
      req
      |> request.set_header(key, value)
      |> make_request(rest, _)
  }
}

pub fn receive_data(state: State, size: Int) -> #(State, Int) {
  let assert #(new_window_size, increment) =
    flow_control.compute_receive_window(state.receive_window_size, size)

  let new_state =
    State(
      ..state,
      receive_window_size: new_window_size,
      pending_content_length: option.map(state.pending_content_length, fn(val) {
        val - size
      }),
    )

  #(new_state, increment)
}
