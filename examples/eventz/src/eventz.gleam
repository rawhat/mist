import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import logging
import mist
import repeatedly

const index_html = "
  <!DOCTYPE html>
  <html lang=\"en\">
    <head><title>eventzzz</title></head>
    <body>
      <div id='time'></div>
      <script>
        const clock = document.getElementById(\"time\")
        const eventz = new EventSource(\"/clock\")
        eventz.onmessage = (e) => {
          console.log(\"got a message\", e)
          const theTime = new Date(parseInt(e.data))
          clock.innerText = theTime.toLocaleString()
        }
        eventz.onclose = () => {
          clock.innerText = \"Done!\"
        }
        // This is not 'ideal' but there is no way to close the connection from
        // the server :(
        eventz.onerror = (e) => {
          eventz.close()
        }
      </script>
    </body>
  </html>
  "

pub type EventState {
  EventState(count: Int, repeater: repeatedly.Repeater(Nil))
}

pub type Event {
  Time(Int)
}

pub fn main() {
  logging.configure()

  let index_resp =
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string(index_html)))

  let assert Ok(_) =
    fn(req) {
      case request.path_segments(req) {
        ["clock"] ->
          mist.server_sent_events(
            req,
            response.new(200),
            init: fn(subj) {
              let repeater =
                repeatedly.call(1000, Nil, fn(_state, _count) {
                  let now = system_time(Millisecond)
                  process.send(subj, Time(now))
                })
              Ok(actor.initialised(EventState(0, repeater)))
            },
            loop: fn(state, message, conn) {
              case message {
                Time(value) -> {
                  let event =
                    mist.event(string_tree.from_string(int.to_string(value)))
                  case mist.send_event(conn, event) {
                    Ok(_) -> {
                      logging.log(
                        logging.Info,
                        "Sent event: " <> string.inspect(event),
                      )
                      actor.continue(
                        EventState(..state, count: state.count + 1),
                      )
                    }
                    Error(_) -> {
                      repeatedly.stop(state.repeater)
                      actor.stop()
                    }
                  }
                }
              }
            },
          )
        _ -> index_resp
      }
    }
    |> mist.new
    |> mist.port(4001)
    |> mist.start

  process.sleep_forever()
}

type Unit {
  Millisecond
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: Unit) -> Int
