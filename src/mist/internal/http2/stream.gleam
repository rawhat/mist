import gleam/dynamic
import gleam/erlang
import gleam/erlang/process.{type Subject}
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
import mist/internal/buffer.{type Buffer}
import mist/internal/http.{
  type Connection, type Handler, type ResponseData, Connection, Initial,
}
import mist/internal/http2/frame.{type Frame, type StreamIdentifier}

pub type Message {
  Headers(headers: List(Header), end_stream: Bool)
  BodyChunk(data: BitArray)
  LastBodyChunk(data: BitArray)
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
    subj: Subject(Message),
    receive_window_size: Int,
    send_window_size: Int,
    pending_content_length: Option(Int),
  )
}

import gleam/io

pub fn new(
  _identifier: StreamIdentifier(any),
  window_size: Int,
  handler: Handler,
  connection: Connection,
  send: fn(Response(ResponseData)) -> todo_resp,
) -> Result(Subject(Message), actor.StartError) {
  actor.start(Nil, fn(msg, state) {
    io.debug(#("our stream got a msg", msg, "with state", state))
    case msg {
      Headers(headers, True) -> {
        let content_length =
          headers
          |> list.key_find("content-length")
          |> result.then(int.parse)
          |> result.unwrap(0)

        case content_length {
          0 -> {
            io.println("we got no content, zoomin")
            headers
            |> make_request(
              request.new()
              |> request.set_body(Nil),
            )
            |> result.map(fn(req) { request.set_body(req, connection) })
            |> result.map(handler)
            |> result.map(fn(resp) {
              io.println("gonna reply with:  " <> erlang.format(resp))
              send(resp)
              // TODO:  send response
              actor.Stop(process.Normal)
            })
            |> result.map_error(fn(err) {
              io.println("oh no, we got an error:  " <> erlang.format(err))
              // TODO:  send close?
              actor.Stop(process.Normal)
            })
            |> result.unwrap_both
          }
          _n -> {
            // TODO:  send an error back
            actor.Stop(process.Normal)
          }
        }
      }
      Headers(headers, False) -> {
        let content_length =
          headers
          |> list.key_find("content-length")
          |> result.then(int.parse)
          |> result.unwrap(0)
        actor.continue(Nil)
      }
      // TODO:  i think i'll need to hook into something like this to handle
      // receiving the data when requested... i'll also need to do whatever
      // this mechanism is _instead_ of the http.{read_body} stuff
      BodyChunk(data) -> actor.continue(Nil)
      LastBodyChunk(data) -> {
        // let body = buffer.append(state.body, data)
        let req =
          request.new()
          |> request.set_body(Connection(..connection, body: Initial(<<>>)))
        let resp = handler(req)
        send(resp)
        actor.Stop(process.Normal)
      }
    }
  })
}

pub fn make_request(
  headers: List(Header),
  req: Request(Nil),
) -> Result(Request(Nil), Nil) {
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
