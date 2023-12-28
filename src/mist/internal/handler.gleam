import gleam/bytes_builder.{type BytesBuilder}
import gleam/dynamic
import gleam/erlang.{Errored, Exited, Thrown, rescue}
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/iterator.{type Iterator}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import glisten.{type Loop, type Message, Packet}
import glisten/handler.{Close, Internal}
import glisten/socket.{type Socket, type SocketReason, Badarg}
import glisten/socket/transport.{type Transport}
import mist/internal/buffer.{type Buffer, Buffer}
import mist/internal/encoder
import mist/internal/file
import mist/internal/http.{
  type Connection, type DecodeError, type Handler, type ResponseData, Bytes,
  Chunked, Connection, DiscardPacket, File, Initial, Websocket,
}
import mist/internal/http2/frame.{Settings}
import mist/internal/http2/stream
import mist/internal/logger

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

const stop_normal = actor.Stop(process.Normal)

pub type Http2Settings {
  Http2Settings(
    header_table_size: Int,
    server_push: frame.PushState,
    max_concurrent_streams: Int,
    initial_window_size: Int,
    max_frame_size: Int,
    max_header_list_size: Option(Int),
  )
}

pub type State {
  Http1(idle_timer: Option(process.Timer))
  Http2(frame_buffer: Buffer, settings: Http2Settings)
}

// Http(idle_timer: Option(process.Timer))
// Http2

pub fn new_state() -> State {
  Http1(None)
}

import gleam/io

/// This is a more flexible handler. It will allow you to upgrade a connection
/// to a websocket connection, or deal with a regular HTTP req->resp workflow.
pub fn with_func(handler: Handler) -> Loop(user_message, State) {
  fn(msg, state: State, conn: glisten.Connection(user_message)) {
    let assert Packet(msg) = msg
    let sender = conn.subject
    let conn =
      Connection(
        body: Initial(<<>>),
        socket: conn.socket,
        transport: conn.transport,
        client_ip: conn.client_ip,
      )

    case state {
      Http1(idle_timer) -> {
        {
          let _ = case idle_timer {
            Some(t) -> process.cancel_timer(t)
            _ -> process.TimerNotFound
          }
          msg
          |> http.parse_request(conn)
          |> result.map_error(fn(err) {
            case err {
              DiscardPacket -> Nil
              _ -> {
                logger.error(err)
                let _ = conn.transport.close(conn.socket)
                Nil
              }
            }
          })
          |> result.replace_error(stop_normal)
          |> result.map(fn(req) {
            case req {
              http.Http1Request(req) -> {
                handle_http1(req, handler, conn, sender)
              }
              http.Upgrade(data) -> {
                let initial_settings =
                  Http2Settings(
                    header_table_size: 4096,
                    server_push: frame.Enabled,
                    max_concurrent_streams: 100,
                    initial_window_size: 65_535,
                    max_frame_size: 16_384,
                    max_header_list_size: None,
                  )
                let settings_frame =
                  frame.Settings(ack: False, settings: [
                    frame.HeaderTableSize(initial_settings.header_table_size),
                    frame.ServerPush(initial_settings.server_push),
                    frame.MaxConcurrentStreams(
                      initial_settings.max_concurrent_streams,
                    ),
                    frame.InitialWindowSize(initial_settings.initial_window_size,
                    ),
                    frame.MaxFrameSize(initial_settings.max_frame_size),
                  ])
                let assert Ok(_nil) =
                  settings_frame
                  |> frame.encode
                  |> bytes_builder.from_bit_array
                  |> conn.transport.send(conn.socket, _)

                frame.decode(data)
                |> result.map_error(fn(_err) {
                  actor.Stop(process.Abnormal("Missing first frame"))
                })
                |> result.then(fn(pair) {
                  let assert #(frame, rest) = pair
                  case frame {
                    Settings(settings: settings, ..) -> {
                      let http2_settings =
                        initial_settings
                        |> list.fold(
                          settings,
                          _,
                          fn(settings, setting) {
                            case setting {
                              frame.HeaderTableSize(size) ->
                                Http2Settings(
                                  ..settings,
                                  header_table_size: size,
                                )
                              frame.ServerPush(push) ->
                                Http2Settings(..settings, server_push: push)
                              frame.MaxConcurrentStreams(max) ->
                                Http2Settings(
                                  ..settings,
                                  max_concurrent_streams: max,
                                )
                              frame.InitialWindowSize(size) ->
                                Http2Settings(
                                  ..settings,
                                  initial_window_size: size,
                                )
                              frame.MaxFrameSize(size) ->
                                Http2Settings(..settings, max_frame_size: size)
                              frame.MaxHeaderListSize(size) ->
                                Http2Settings(
                                  ..settings,
                                  max_header_list_size: Some(size),
                                )
                            }
                          },
                        )
                      Ok(
                        actor.continue(Http2(
                          frame_buffer: buffer.new(rest),
                          settings: http2_settings,
                        )),
                      )
                    }
                    _ -> {
                      let assert Ok(_) = conn.transport.close(conn.socket)
                      Error(
                        actor.Stop(process.Abnormal(
                          "SETTINGS frame must be sent first",
                        )),
                      )
                    }
                  }
                })
                |> result.unwrap_both
              }
            }
          })
        }
        |> result.unwrap_both
      }
      Http2(frame_buffer, settings) -> {
        let new_buffer = buffer.append(frame_buffer, msg)
        case frame.decode(new_buffer.data) {
          Ok(#(frame.WindowUpdate(amount, identifier), rest)) -> {
            case frame.get_stream_identifier(identifier) {
              0 -> {
                io.println("setting window size!")
                actor.continue(Http2(
                  frame_buffer: buffer.new(rest),
                  settings: Http2Settings(
                    ..settings,
                    initial_window_size: amount,
                  ),
                ))
              }
              _n -> {
                todo
              }
            }
          }
          Ok(#(frame.Header(data, _end_stream, identifier, _priority), rest)) -> {
            let conn =
              Connection(
                body: Initial(<<>>),
                socket: conn.socket,
                transport: conn.transport,
                client_ip: conn.client_ip,
              )
            let assert Ok(new_stream) =
              stream.new(identifier, settings.initial_window_size, handler, conn,
              )
            let assert frame.Complete(data) = data
            process.send(new_stream, stream.HeaderChunk(data))
            actor.continue(Http2(
              frame_buffer: buffer.new(rest),
              settings: settings,
            ))
          }
          Ok(data) -> {
            io.debug(#("we got a frame!!111oneone", data))
            todo
          }
          Error(frame.NoError) -> {
            actor.continue(Http2(frame_buffer: new_buffer, settings: settings))
          }
          Error(_connection_error) -> {
            // TODO:
            //  - send GOAWAY with last good stream ID
            //  - close the connection
            todo
          }
        }
      }
    }
  }
}

fn log_and_error(
  error: erlang.Crash,
  socket: Socket,
  transport: Transport,
) -> actor.Next(Message(user_message), State) {
  case error {
    Exited(msg) | Thrown(msg) | Errored(msg) -> {
      logger.error(error)
      response.new(500)
      |> response.set_body(
        bytes_builder.from_bit_array(<<"Internal Server Error":utf8>>),
      )
      |> response.prepend_header("content-length", "21")
      |> http.add_default_headers
      |> encoder.to_bytes_builder
      |> transport.send(socket, _)
      let _ = transport.close(socket)
      actor.Stop(process.Abnormal(dynamic.unsafe_coerce(msg)))
    }
  }
}

fn handle_http1(
  req: Request(Connection),
  handler: Handler,
  conn: Connection,
  sender: Subject(handler.Message(user_message)),
) -> actor.Next(Message(user_message), State) {
  rescue(fn() { handler(req) })
  |> result.map_error(log_and_error(_, conn.socket, conn.transport))
  |> result.map(fn(resp) {
    case resp {
      response.Response(body: Websocket(selector), ..) -> {
        let _resp = process.select_forever(selector)
        actor.Stop(process.Normal)
      }
      response.Response(body: body, ..) as resp -> {
        case body {
          Bytes(body) -> handle_bytes_builder_body(resp, body, conn)
          Chunked(body) -> handle_chunked_body(resp, body, conn)
          File(..) -> handle_file_body(resp, body, conn)
          _ -> panic as "This shouldn't ever happen 🤞"
        }
        |> result.map(fn(_res) { close_or_set_timer(resp, conn, sender) })
        |> result.replace_error(stop_normal)
        |> result.unwrap_both
      }
    }
  })
  |> result.unwrap_both
}

fn close_or_set_timer(
  resp: response.Response(ResponseData),
  conn: Connection,
  sender: Subject(handler.Message(user_message)),
) -> actor.Next(Message(user_message), State) {
  // If the handler explicitly says to close the connection, we should
  // probably listen to them
  case response.get_header(resp, "connection") {
    Ok("close") -> {
      let _ = conn.transport.close(conn.socket)
      stop_normal
    }
    _ -> {
      // TODO:  this should be a configuration
      let timer = process.send_after(sender, 10_000, Internal(Close))
      actor.continue(Http1(idle_timer: Some(timer)))
    }
  }
}

fn handle_bytes_builder_body(
  resp: response.Response(ResponseData),
  body: BytesBuilder,
  conn: Connection,
) -> Result(Nil, SocketReason) {
  resp
  |> response.set_body(body)
  |> http.add_default_headers
  |> encoder.to_bytes_builder
  |> conn.transport.send(conn.socket, _)
}

fn int_to_hex(int: Int) -> String {
  integer_to_list(int, 16)
}

fn handle_chunked_body(
  resp: response.Response(ResponseData),
  body: Iterator(BytesBuilder),
  conn: Connection,
) -> Result(Nil, SocketReason) {
  let headers = [#("transfer-encoding", "chunked"), ..resp.headers]
  let initial_payload = encoder.response_builder(resp.status, headers)

  conn.transport.send(conn.socket, initial_payload)
  |> result.then(fn(_ok) {
    body
    |> iterator.append(iterator.from_list([bytes_builder.new()]))
    |> iterator.try_fold(Nil, fn(_prev, chunk) {
      let size = bytes_builder.byte_size(chunk)
      let encoded =
        size
        |> int_to_hex
        |> bytes_builder.from_string
        |> bytes_builder.append_string("\r\n")
        |> bytes_builder.append_builder(chunk)
        |> bytes_builder.append_string("\r\n")

      conn.transport.send(conn.socket, encoded)
    })
  })
  |> result.replace(Nil)
}

fn handle_file_body(
  resp: response.Response(ResponseData),
  body: ResponseData,
  conn: Connection,
) -> Result(Nil, SocketReason) {
  let assert File(file_descriptor, offset, length) = body
  resp
  |> response.prepend_header("content-length", int.to_string(length - offset))
  |> response.set_body(bytes_builder.new())
  |> fn(r: response.Response(BytesBuilder)) {
    encoder.response_builder(resp.status, r.headers)
  }
  |> conn.transport.send(conn.socket, _)
  |> result.then(fn(_) {
    file.sendfile(file_descriptor, conn.socket, offset, length, [])
    |> result.map_error(fn(err) { logger.error(#("Failed to send file", err)) })
    |> result.replace_error(Badarg)
  })
  |> result.replace(Nil)
}

/// Creates a standard HTTP handler service to pass to `mist.serve`
@external(erlang, "erlang", "integer_to_list")
fn integer_to_list(int int: Int, base base: Int) -> String
