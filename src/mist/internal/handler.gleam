import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/response
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import glisten.{type Loop, Packet, User}
import glisten/transport
import logging
import mist/internal/encoder
import mist/internal/http.{
  type DecodeError, type Handler, Bytes, Chunked, Connection, DiscardPacket,
  File, Initial, ServerSentEvents, Websocket,
}
import mist/internal/http/handler as http_handler
import mist/internal/http2
import mist/internal/http2/handler as http2_handler
import mist/internal/http2/stream.{type SendMessage, Send}

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

pub type State {
  Http1(state: http_handler.State, self: Subject(SendMessage))
  Http2(state: http2_handler.State)
  AwaitingH2cPreface(self: Subject(SendMessage), settings: Option(http2.Http2Settings), buffer: BitArray)
}

pub type Config {
  Config(http2_settings: Option(http2.Http2Settings))
}

pub fn new_state(subj: Subject(SendMessage)) -> State {
  Http1(http_handler.initial_state(), subj)
}

pub fn init(_conn) -> #(State, Option(Selector(SendMessage))) {
  let subj = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(subj)

  #(new_state(subj), Some(selector))
}

pub fn init_with_config(
  _config: Option(http2.Http2Settings),
) -> fn(glisten.Connection(SendMessage)) ->
  #(State, Option(Selector(SendMessage))) {
  fn(_conn) {
    let subj = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(subj)

    #(new_state(subj), Some(selector))
  }
}

pub fn with_func(handler: Handler) -> Loop(State, SendMessage) {
  with_func_and_config(None, handler)
}

pub fn with_func_and_config(
  http2_settings: Option(http2.Http2Settings),
  handler: Handler,
) -> Loop(State, SendMessage) {
  fn(state: State, msg, conn: glisten.Connection(SendMessage)) {
    let sender = conn.subject
    let conn =
      Connection(
        body: Initial(<<>>),
        socket: conn.socket,
        transport: conn.transport,
      )

    case msg, state {
      User(Send(..)), Http1(..) -> {
        Error(Error("Attempted to send HTTP/2 response without upgrade"))
      }
      User(Send(id, resp)), Http2(state) -> {
        case resp.body {
          Bytes(bytes) -> {
            resp
            |> response.set_body(bytes)
            |> http2.send_bytes_tree(conn, state.send_hpack_context, id)
          }
          File(..) -> Error("File sending unsupported over HTTP/2")
          // TODO:  properly error in some fashion for these
          Websocket(_selector) -> Error("WebSocket unsupported for HTTP/2")
          Chunked(_iterator) ->
            Error("Chunked encoding not supported for HTTP/2")
          ServerSentEvents(_selector) ->
            Error("Server-Sent Events unsupported for HTTP/2")
        }
        |> result.map(fn(context) {
          Http2(http2_handler.send_hpack_context(state, context))
        })
        |> result.map_error(fn(err) {
          logging.log(
            logging.Debug,
            "Error sending HTTP/2 data: " <> string.inspect(err),
          )
          Error(string.inspect(err))
        })
      }
      Packet(msg), Http1(state, self) -> {
        let _ = 
          state.idle_timer
          |> option.map(process.cancel_timer)
          |> option.unwrap(process.TimerNotFound)
        msg
        |> http.parse_request(conn)
        |> result.map_error(fn(err) {
          case err {
            DiscardPacket -> Ok(Nil)
            _ -> {
              logging.log(logging.Error, string.inspect(err))
              let _ = transport.close(conn.transport, conn.socket)
              Error("Received invalid request")
            }
          }
        })
        |> result.try(fn(req) {
          case req {
            http.Http1Request(req, version) ->
              http_handler.call(req, handler, conn, sender, version)
              |> result.map(fn(new_state) {
                Http1(state: new_state, self: self)
              })
            http.Upgrade(data) ->
              http2_handler.upgrade_with_settings(
                data,
                conn,
                self,
                http2_settings,
              )
              |> result.map(Http2)
              |> result.map_error(Error)
            http.H2cUpgrade(_req, _settings) -> {
              // Send 101 Switching Protocols response
              let resp_101 = 
                response.new(101)
                |> response.set_body(bytes_tree.new())
                |> response.set_header("connection", "Upgrade")
                |> response.set_header("upgrade", "h2c")
              
              // Send the 101 response
              let _ = 
                resp_101
                |> encoder.to_bytes_tree("1.1")
                |> transport.send(conn.transport, conn.socket, _)
              
              // Switch to raw mode to handle HTTP/2 frames
              let _ = http.set_socket_packet_mode(
                conn.transport,
                conn.socket,
                http.RawPacket
              )
              
              // Set socket to receive the next packet
              let _ = http.set_socket_active(conn.transport, conn.socket)
              
              // Wait for the HTTP/2 preface in the next packet
              Ok(AwaitingH2cPreface(self, http2_settings, <<>>))
            }
          }
        })
      }
      Packet(msg), Http2(state) -> {
        state
        |> http2_handler.append_data(msg)
        |> http2_handler.call(conn, handler)
        |> result.map(Http2)
      }
      Packet(msg), AwaitingH2cPreface(self, http2_settings, buffer) -> {
        // Accumulate data until we have the complete preface
        let accumulated = bit_array.append(buffer, msg)
        
        case accumulated {
          <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8, rest:bits>> -> {
            logging.log(logging.Debug, "Received complete HTTP/2 preface, upgrading to HTTP/2")
            // Set socket to active true for continuous HTTP/2 communication
            let _ = http.set_socket_active_continuous(conn.transport, conn.socket)
            
            // Initialize HTTP/2 handler with any remaining data
            http2_handler.upgrade_with_settings(
              rest,
              conn,
              self,
              http2_settings,
            )
            |> result.map(Http2)
            |> result.map_error(Error)
          }
          _ -> {
            // Check if we have part of the preface
            let preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>>
            let preface_size = bit_array.byte_size(preface)
            let accumulated_size = bit_array.byte_size(accumulated)
            
            case accumulated_size >= preface_size {
              True -> {
                // We have enough data but it doesn't match the preface
                logging.log(logging.Error, "Invalid HTTP/2 preface received: " <> string.inspect(accumulated))
                Error(Error("Invalid HTTP/2 preface"))
              }
              False -> {
                // Check if what we have so far matches the beginning of the preface
                let matches = case accumulated {
                  <<"PRI":utf8, _:bits>> -> True
                  <<"PR":utf8, _:bits>> -> True
                  <<"P":utf8, _:bits>> -> True
                  <<>> -> True
                  _ -> {
                    // Check if it matches the start of the preface at any position
                    let assert <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8>> = preface
                    bit_array.slice(preface, 0, accumulated_size) 
                    |> result.map(fn(prefix) { bit_array.compare(accumulated, prefix) == order.Eq })
                    |> result.unwrap(False)
                  }
                }
                
                case matches {
                  True -> {
                    logging.log(logging.Debug, "Partial HTTP/2 preface received, waiting for more: " <> string.inspect(accumulated))
                    // Set socket to receive the next packet
                    let _ = http.set_socket_active(conn.transport, conn.socket)
                    Ok(AwaitingH2cPreface(self, http2_settings, accumulated))
                  }
                  False -> {
                    logging.log(logging.Error, "Invalid HTTP/2 preface start: " <> string.inspect(accumulated))
                    Error(Error("Invalid HTTP/2 preface"))
                  }
                }
              }
            }
          }
        }
      }
      User(_), AwaitingH2cPreface(..) -> {
        // Ignore user messages while waiting for preface
        Ok(state)
      }
    }
    |> result.map(glisten.continue)
    |> result.map_error(fn(err) {
      case err {
        Ok(_nil) -> glisten.stop()
        Error(reason) -> glisten.stop_abnormal(reason)
      }
    })
    |> result.unwrap_both
  }
}
