import gleam/dynamic
import gleam/erlang.{rescue}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import glisten.{type Socket}
import glisten/socket/options
import glisten/transport.{type Transport}
import gramps/websocket.{
  type Frame, type ParsedFrame, CloseFrame, Control, InvalidFrame, NeedMoreData,
  PingFrame, PongFrame,
}
import gramps/websocket/compression.{type Compression, type Context}
import logging

pub type ValidMessage(user_message) {
  SocketMessage(BitArray)
  SocketClosedMessage
  UserMessage(user_message)
}

pub type WebsocketMessage(user_message) {
  Valid(ValidMessage(user_message))
  Invalid
}

pub type WebsocketConnection {
  WebsocketConnection(
    socket: Socket,
    transport: Transport,
    deflate: Option(Context),
  )
}

pub type HandlerMessage(user_message) {
  Internal(Frame)
  User(user_message)
}

pub type WebsocketState(state) {
  WebsocketState(
    buffer: BitArray,
    user: state,
    permessage_deflate: Option(Compression),
  )
}

pub type Handler(state, message) =
  fn(state, WebsocketConnection, HandlerMessage(message)) ->
    actor.Next(message, state)

// TODO: this is pulled straight from glisten, prob should share it
fn message_selector() -> Selector(WebsocketMessage(user_message)) {
  process.new_selector()
  |> process.selecting_record3(atom.create_from_string("tcp"), fn(_sock, data) {
    data
    |> dynamic.bit_array
    |> result.replace_error(Nil)
    |> result.map(SocketMessage)
    |> result.map(Valid)
    |> result.unwrap(Invalid)
  })
  |> process.selecting_record3(atom.create_from_string("ssl"), fn(_sock, data) {
    data
    |> dynamic.bit_array
    |> result.replace_error(Nil)
    |> result.map(SocketMessage)
    |> result.map(Valid)
    |> result.unwrap(Invalid)
  })
  |> process.selecting_record2(atom.create_from_string("ssl_closed"), fn(_nil) {
    Valid(SocketClosedMessage)
  })
  |> process.selecting_record2(atom.create_from_string("tcp_closed"), fn(_nil) {
    Valid(SocketClosedMessage)
  })
}

pub fn initialize_connection(
  on_init: fn(WebsocketConnection) -> #(state, Option(Selector(user_message))),
  on_close: fn(state) -> Nil,
  handler: Handler(state, user_message),
  socket: Socket,
  transport: Transport,
  extensions: List(String),
) -> Result(Subject(WebsocketMessage(user_message)), Nil) {
  actor.start_spec(
    actor.Spec(
      init: fn() {
        let compression = case websocket.has_deflate(extensions) {
          True -> Some(compression.init())
          False -> None
        }
        let connection =
          WebsocketConnection(
            socket: socket,
            transport: transport,
            deflate: option.map(compression, fn(compression) {
              compression.deflate
            }),
          )
        let #(initial_state, user_selector) = on_init(connection)
        let selector = case user_selector {
          Some(user_selector) ->
            user_selector
            |> process.map_selector(UserMessage)
            |> process.map_selector(Valid)
            |> process.merge_selector(message_selector())
          _ -> message_selector()
        }
        actor.Ready(
          WebsocketState(
            buffer: <<>>,
            user: initial_state,
            permessage_deflate: compression,
          ),
          selector,
        )
      },
      init_timeout: 500,
      loop: fn(msg, state) {
        let connection =
          WebsocketConnection(
            socket: socket,
            transport: transport,
            deflate: option.map(state.permessage_deflate, fn(compression) {
              compression.deflate
            }),
          )
        case msg {
          Valid(SocketMessage(data)) -> {
            let #(frames, rest) =
              get_messages(
                <<state.buffer:bits, data:bits>>,
                [],
                option.map(state.permessage_deflate, fn(compression) {
                  compression.inflate
                }),
              )
            frames
            |> websocket.aggregate_frames(None, [])
            |> result.map(fn(frames) {
              let next =
                apply_frames(
                  frames,
                  handler,
                  connection,
                  actor.continue(state.user),
                  on_close,
                )
              case next {
                actor.Continue(user_state, selector) -> {
                  actor.Continue(
                    WebsocketState(..state, buffer: rest, user: user_state),
                    selector,
                  )
                }
                actor.Stop(reason) -> {
                  let _ =
                    option.map(state.permessage_deflate, fn(contexts) {
                      compression.close(contexts.deflate)
                      compression.close(contexts.inflate)
                    })
                  actor.Stop(reason)
                }
              }
            })
            |> result.lazy_unwrap(fn() {
              logging.log(logging.Error, "Received a malformed WebSocket frame")
              on_close(state.user)
              let _ =
                option.map(state.permessage_deflate, fn(contexts) {
                  compression.close(contexts.deflate)
                  compression.close(contexts.inflate)
                })
              actor.Stop(process.Abnormal(
                "WebSocket received a malformed message",
              ))
            })
          }
          Valid(UserMessage(msg)) -> {
            rescue(fn() { handler(state.user, connection, User(msg)) })
            |> result.map(fn(cont) {
              case cont {
                actor.Continue(user_state, selector) -> {
                  let selector =
                    selector
                    |> map_user_selector
                    |> option.map(fn(with_user) {
                      process.merge_selector(message_selector(), with_user)
                    })
                  actor.Continue(
                    WebsocketState(..state, user: user_state),
                    selector,
                  )
                }
                actor.Stop(reason) -> {
                  let _ =
                    option.map(state.permessage_deflate, fn(contexts) {
                      compression.close(contexts.deflate)
                      compression.close(contexts.inflate)
                    })
                  on_close(state.user)
                  actor.Stop(reason)
                }
              }
            })
            |> result.map_error(fn(err) {
              logging.log(
                logging.Error,
                "Caught error in websocket handler: " <> erlang.format(err),
              )
            })
            |> result.lazy_unwrap(fn() {
              let _ =
                option.map(state.permessage_deflate, fn(contexts) {
                  compression.close(contexts.deflate)
                  compression.close(contexts.inflate)
                })
              on_close(state.user)
              actor.Stop(process.Abnormal("Crash in user websocket handler"))
            })
          }
          Valid(SocketClosedMessage) -> {
            let _ =
              option.map(state.permessage_deflate, fn(contexts) {
                compression.close(contexts.deflate)
                compression.close(contexts.inflate)
              })
            on_close(state.user)
            actor.Stop(process.Normal)
          }
          // TODO:  do we need to send something back for this?
          Invalid -> {
            logging.log(logging.Error, "Received a malformed WebSocket frame")
            let _ =
              option.map(state.permessage_deflate, fn(contexts) {
                compression.close(contexts.deflate)
                compression.close(contexts.inflate)
              })
            on_close(state.user)
            actor.Stop(process.Abnormal(
              "WebSocket received a malformed message",
            ))
          }
        }
      },
    ),
  )
  |> result.replace_error(Nil)
  |> result.map(fn(subj) {
    let websocket_pid = process.subject_owner(subj)
    let assert Ok(_) =
      transport.controlling_process(transport, socket, websocket_pid)
    set_active(transport, socket)
    subj
  })
  |> result.replace_error(Nil)
}

fn get_messages(
  data: BitArray,
  frames: List(ParsedFrame),
  context: Option(Context),
) -> #(List(ParsedFrame), BitArray) {
  case websocket.frame_from_message(data, context) {
    Ok(#(frame, <<>>)) -> #(list.reverse([frame, ..frames]), <<>>)
    Ok(#(frame, rest)) -> get_messages(rest, [frame, ..frames], context)
    Error(NeedMoreData(rest)) -> #(list.reverse(frames), rest)
    Error(InvalidFrame) -> #(list.reverse(frames), data)
  }
}

fn apply_frames(
  frames: List(Frame),
  handler: Handler(state, user_message),
  connection: WebsocketConnection,
  next: actor.Next(WebsocketMessage(user_message), state),
  on_close: fn(state) -> Nil,
) -> actor.Next(WebsocketMessage(user_message), state) {
  case frames, next {
    _, actor.Stop(reason) -> actor.Stop(reason)
    [], next -> {
      set_active(connection.transport, connection.socket)
      next
    }
    [Control(CloseFrame(..)) as frame, ..], actor.Continue(state, _selector) -> {
      let _ =
        transport.send(
          connection.transport,
          connection.socket,
          websocket.frame_to_bytes_builder(frame, None),
        )
      on_close(state)
      actor.Stop(process.Normal)
    }
    [Control(PingFrame(length, payload)), ..], actor.Continue(state, _selector) -> {
      transport.send(
        connection.transport,
        connection.socket,
        websocket.frame_to_bytes_builder(
          Control(PongFrame(length, payload)),
          None,
        ),
      )
      |> result.map(fn(_nil) {
        set_active(connection.transport, connection.socket)
        actor.continue(state)
      })
      |> result.lazy_unwrap(fn() {
        on_close(state)
        actor.Stop(process.Abnormal("Failed to send pong frame"))
      })
    }
    [frame, ..rest], actor.Continue(state, prev_selector) -> {
      case rescue(fn() { handler(state, connection, Internal(frame)) }) {
        Ok(actor.Continue(state, selector)) -> {
          let next_selector =
            selector
            |> map_user_selector
            |> option.or(prev_selector)
            |> option.map(fn(with_user) {
              process.merge_selector(message_selector(), with_user)
            })

          apply_frames(
            rest,
            handler,
            connection,
            actor.Continue(state, next_selector),
            on_close,
          )
        }
        Ok(actor.Stop(reason)) -> {
          on_close(state)
          actor.Stop(reason)
        }
        Error(reason) -> {
          logging.log(
            logging.Error,
            "Caught error in websocket handler: " <> erlang.format(reason),
          )
          on_close(state)
          actor.Stop(process.Abnormal("Crash in user websocket handler"))
        }
      }
    }
  }
}

fn set_active(transport: Transport, socket: Socket) -> Nil {
  let assert Ok(_) =
    transport.set_opts(transport, socket, [options.ActiveMode(options.Once)])

  Nil
}

fn map_user_selector(
  selector: Option(Selector(user_message)),
) -> Option(Selector(WebsocketMessage(user_message))) {
  option.map(selector, process.map_selector(_, fn(msg) {
    Valid(UserMessage(msg))
  }))
}
