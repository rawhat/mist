import exception
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Selector}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import glisten.{type Socket}
import glisten/socket/options
import glisten/transport.{type Transport}
import gramps/websocket.{type Frame, CloseFrame, Control, PingFrame}
import gramps/websocket/compression.{type Compression, type Context}
import gramps/websocket/decoder
import logging
import mist/internal/next.{type Next, AbnormalStop, Continue, NormalStop}

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
    decoder: Option(decoder.Decoder),
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
) -> Result(actor.Started(process.Pid), actor.StartError) {
  initialize_connection_with_decoder(
    on_init,
    on_close,
    handler,
    socket,
    transport,
    extensions,
    None,
  )
}

/// Starts a connection with an optional bounded, uncompressed decoder.
pub fn initialize_connection_with_decoder(
  on_init: fn(WebsocketConnection) -> #(state, Option(Selector(user_message))),
  on_close: fn(state) -> Nil,
  handler: Handler(state, user_message),
  socket: Socket,
  transport: Transport,
  extensions: List(String),
  decoder: Option(decoder.Decoder),
) -> Result(actor.Started(process.Pid), actor.StartError) {
  let takeovers = websocket.get_context_takeovers(extensions)
  actor.new_with_initialiser(500, fn(subject) {
    let compression = case websocket.has_deflate(extensions) {
      True -> Some(compression.init(takeovers))
      False -> None
    }
    let connection =
      WebsocketConnection(
        socket:,
        transport:,
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
      decoder:,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, msg) {
    let connection =
      WebsocketConnection(
        socket:,
        transport:,
        deflate: option.map(state.permessage_deflate, fn(compression) {
          compression.deflate
        }),
      )
    case msg {
      Valid(SocketMessage(data)) -> {
        let decoded = case state.decoder {
          Some(bounded) -> {
            let #(bounded, next) =
              receive_bounded(
                bounded,
                data,
                handler,
                connection,
                Continue(state.user, None),
                on_close,
              )
            Ok(#(<<>>, Some(bounded), next))
          }
          None -> {
            let #(frames, rest) =
              websocket.decode_many_frames(
                <<state.buffer:bits, data:bits>>,
                option.map(state.permessage_deflate, fn(compression) {
                  compression.inflate
                }),
                [],
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
              #(rest, None, next)
            })
          }
        }
        decoded
        |> result.map(fn(decoded) {
          let #(rest, bounded, next) = decoded
          case next {
            Continue(user_state, selector) -> {
              // Rearm once after the entire TCP chunk has been handled. Doing
              // this per decoded frame admits extra chunks into the mailbox.
              set_active(connection.transport, connection.socket)
              let next =
                actor.continue(
                  WebsocketState(
                    ..state,
                    buffer: rest,
                    user: user_state,
                    decoder: bounded,
                  ),
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
        exception.rescue(fn() { handler(state.user, User(msg), connection) })
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
                transport.send(
                  connection.transport,
                  connection.socket,
                  websocket.encode_close_frame(websocket.Normal(<<>>), None),
                )
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
                transport.send(
                  connection.transport,
                  connection.socket,
                  websocket.encode_close_frame(
                    websocket.CustomCloseReason(
                      4000,
                      bit_array.from_string(reason),
                    ),
                    None,
                  ),
                )
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
        |> result.map_error(fn(_err) {
          logging.log(logging.Error, "Caught error in websocket handler")
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
  |> result.map(fn(subj) {
    let assert Ok(websocket_pid) = process.subject_owner(subj.data)
    actor.Started(websocket_pid, websocket_pid)
  })
}

// Deliver one message at a time, leaving later input undecoded while its user
// callback runs. The decoder retains fragments across TCP chunks and rejects
// an oversized declared payload before copying or unmasking its contents.
fn receive_bounded(
  bounded: decoder.Decoder,
  data: BitArray,
  handler: Handler(state, user_message),
  connection: WebsocketConnection,
  next: Next(state, WebsocketMessage(user_message)),
  on_close: fn(state) -> Nil,
) -> #(decoder.Decoder, Next(state, WebsocketMessage(user_message))) {
  case next {
    NormalStop | AbnormalStop(_) -> #(bounded, next)
    Continue(user, _) ->
      case decoder.next(bounded, data) {
        Ok(decoder.More(bounded)) -> #(bounded, next)
        Ok(decoder.Frame(frame, bounded, rest)) -> {
          let next = apply_frames([frame], handler, connection, next, on_close)
          receive_bounded(bounded, rest, handler, connection, next, on_close)
        }
        Error(error) -> {
          let reason = case error {
            decoder.FrameTooLarge | decoder.MessageTooLarge ->
              websocket.MessageTooBig(<<>>)
            decoder.CompressionUnsupported | decoder.InvalidFrame ->
              websocket.ProtocolError(<<>>)
          }
          let _ =
            transport.send(
              connection.transport,
              connection.socket,
              websocket.encode_close_frame(reason, None),
            )
          on_close(user)
          #(
            bounded,
            AbnormalStop(
              "WebSocket input exceeded its limits or violated the protocol",
            ),
          )
        }
      }
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
    [], next -> next
    [Control(CloseFrame(reason)), ..], Continue(state, _selector) -> {
      let _ =
        transport.send(
          connection.transport,
          connection.socket,
          websocket.encode_close_frame(reason, None),
        )
      on_close(state)
      NormalStop
    }
    [Control(PingFrame(payload)), ..rest],
      Continue(state, _selector) as continue
    -> {
      transport.send(
        connection.transport,
        connection.socket,
        websocket.encode_pong_frame(payload, None),
      )
      |> result.map(fn(_nil) {
        apply_frames(rest, handler, connection, continue, on_close)
      })
      |> result.lazy_unwrap(fn() {
        on_close(state)
        AbnormalStop("Failed to send pong frame")
      })
    }
    [frame, ..rest], Continue(state, prev_selector) -> {
      case
        exception.rescue(fn() { handler(state, Internal(frame), connection) })
      {
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
          let _ =
            transport.send(
              connection.transport,
              connection.socket,
              websocket.encode_close_frame(
                websocket.CustomCloseReason(4000, bit_array.from_string(reason)),
                None,
              ),
            )
          on_close(state)
          AbnormalStop(reason)
        }
        Ok(NormalStop) -> {
          let _ =
            transport.send(
              connection.transport,
              connection.socket,
              websocket.encode_close_frame(websocket.Normal(<<>>), None),
            )
          on_close(state)
          NormalStop
        }
        Error(_reason) -> {
          logging.log(logging.Error, "Caught error in websocket handler")
          on_close(state)
          AbnormalStop("Crash in user websocket handler")
        }
      }
    }
  }
}

pub fn set_active(transport: Transport, socket: Socket) -> Nil {
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
