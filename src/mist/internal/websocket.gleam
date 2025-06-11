import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import glisten.{type Socket}
import glisten/socket/options
import glisten/transport.{type Transport}
import gramps/websocket.{
  type Frame, type ParsedFrame, CloseFrame, Control, InvalidFrame, NeedMoreData,
  PingFrame, PongFrame,
}
import gramps/websocket/compression.{type Compression, type Context}
import logging
import mist/internal/next.{type Next, AbnormalStop, Continue, NormalStop}

@external(erlang, "mist_ffi", "rescue")
fn rescue(func: fn() -> return) -> Result(return, Nil)

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
  fn(state, HandlerMessage(message), WebsocketConnection) ->
    Next(state, message)

// TODO: this is pulled straight from glisten, prob should share it
fn message_selector() -> Selector(WebsocketMessage(user_message)) {
  process.new_selector()
  |> process.select_record(atom.create("tcp"), 2, fn(record) {
    {
      use data <- decode.field(2, decode.bit_array)
      decode.success(SocketMessage(data))
    }
    |> decode.run(record, _)
    |> result.replace_error(Nil)
    |> result.map(Valid)
    |> result.unwrap(Invalid)
  })
  |> process.select_record(atom.create("ssl"), 2, fn(record) {
    {
      use data <- decode.field(2, decode.bit_array)
      decode.success(SocketMessage(data))
    }
    |> decode.run(record, _)
    |> result.replace_error(Nil)
    |> result.map(Valid)
    |> result.unwrap(Invalid)
  })
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_nil) {
    Valid(SocketClosedMessage)
  })
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_nil) {
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
) -> Result(actor.Started(Subject(WebsocketMessage(user_message))), Nil) {
  actor.new_with_initialiser(500, fn(subject) {
    let compression = case websocket.has_deflate(extensions) {
      True -> Some(compression.init())
      False -> None
    }
    let connection =
      WebsocketConnection(
        socket: socket,
        transport: transport,
        deflate: option.map(compression, fn(compression) { compression.deflate }),
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
    WebsocketState(
      buffer: <<>>,
      user: initial_state,
      permessage_deflate: compression,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, msg) {
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
              Continue(state.user, None),
              on_close,
            )
          case next {
            Continue(user_state, selector) -> {
              let next =
                actor.continue(
                  WebsocketState(..state, buffer: rest, user: user_state),
                )
              case selector {
                Some(selector) -> actor.with_selector(next, selector)
                _ -> next
              }
            }
            NormalStop -> {
              let _ =
                option.map(state.permessage_deflate, fn(contexts) {
                  compression.close(contexts.deflate)
                  compression.close(contexts.inflate)
                })
              actor.stop()
            }
            AbnormalStop(reason) -> {
              let _ =
                option.map(state.permessage_deflate, fn(contexts) {
                  compression.close(contexts.deflate)
                  compression.close(contexts.inflate)
                })
              actor.stop_abnormal(reason)
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
          actor.stop_abnormal("WebSocket received a malformed message")
        })
      }
      Valid(UserMessage(msg)) -> {
        rescue(fn() { handler(state.user, User(msg), connection) })
        |> result.map(fn(cont) {
          case cont {
            Continue(user_state, selector) -> {
              let selector =
                selector
                |> map_user_selector
                |> option.map(fn(with_user) {
                  process.merge_selector(message_selector(), with_user)
                })
              let next =
                actor.continue(WebsocketState(..state, user: user_state))
              case selector {
                Some(selector) -> actor.with_selector(next, selector)
                _ -> next
              }
            }
            NormalStop -> {
              let _ =
                option.map(state.permessage_deflate, fn(contexts) {
                  compression.close(contexts.deflate)
                  compression.close(contexts.inflate)
                })
              on_close(state.user)
              actor.stop()
            }
            AbnormalStop(reason) -> {
              let _ =
                option.map(state.permessage_deflate, fn(contexts) {
                  compression.close(contexts.deflate)
                  compression.close(contexts.inflate)
                })
              on_close(state.user)
              actor.stop_abnormal(reason)
            }
          }
        })
        |> result.map_error(fn(err) {
          logging.log(
            logging.Error,
            "Caught error in websocket handler: " <> string.inspect(err),
          )
        })
        |> result.lazy_unwrap(fn() {
          let _ =
            option.map(state.permessage_deflate, fn(contexts) {
              compression.close(contexts.deflate)
              compression.close(contexts.inflate)
            })
          on_close(state.user)
          actor.stop_abnormal("Crash in user websocket handler")
        })
      }
      Valid(SocketClosedMessage) -> {
        let _ =
          option.map(state.permessage_deflate, fn(contexts) {
            compression.close(contexts.deflate)
            compression.close(contexts.inflate)
          })
        on_close(state.user)
        actor.stop()
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
        actor.stop_abnormal("WebSocket received a malformed message")
      }
    }
  })
  |> actor.start
  |> result.replace_error(Nil)
  |> result.map(fn(subj) {
    let assert Ok(websocket_pid) = process.subject_owner(subj.data)
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
  next: Next(state, WebsocketMessage(user_message)),
  on_close: fn(state) -> Nil,
) -> Next(state, WebsocketMessage(user_message)) {
  case frames, next {
    _, AbnormalStop(reason) -> AbnormalStop(reason)
    _, NormalStop -> NormalStop
    [], next -> {
      set_active(connection.transport, connection.socket)
      next
    }
    [Control(CloseFrame(..)) as frame, ..], Continue(state, _selector) -> {
      let _ =
        transport.send(
          connection.transport,
          connection.socket,
          websocket.frame_to_bytes_tree(frame, None),
        )
      on_close(state)
      NormalStop
    }
    [Control(PingFrame(length, payload)), ..], Continue(state, _selector) -> {
      transport.send(
        connection.transport,
        connection.socket,
        websocket.frame_to_bytes_tree(Control(PongFrame(length, payload)), None),
      )
      |> result.map(fn(_nil) {
        set_active(connection.transport, connection.socket)
        Continue(state, None)
      })
      |> result.lazy_unwrap(fn() {
        on_close(state)
        AbnormalStop("Failed to send pong frame")
      })
    }
    [frame, ..rest], Continue(state, prev_selector) -> {
      case rescue(fn() { handler(state, Internal(frame), connection) }) {
        Ok(Continue(state, selector)) -> {
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
            Continue(state, next_selector),
            on_close,
          )
        }
        Ok(AbnormalStop(reason)) -> {
          on_close(state)
          AbnormalStop(reason)
        }
        Ok(NormalStop) -> {
          on_close(state)
          NormalStop
        }
        Error(reason) -> {
          logging.log(
            logging.Error,
            "Caught error in websocket handler: " <> string.inspect(reason),
          )
          on_close(state)
          AbnormalStop("Crash in user websocket handler")
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
  option.map(
    selector,
    process.map_selector(_, fn(msg) { Valid(UserMessage(msg)) }),
  )
}
