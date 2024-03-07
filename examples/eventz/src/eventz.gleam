import gleam/bytes_builder
import gleam/erlang/process
import gleam/function
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/otp/actor
import gleam/string_builder
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
  Down(process.ProcessDown)
}

pub fn main() {
  let index_resp =
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_builder.from_string(index_html)))

  let assert Ok(_) =
    fn(req) {
      case request.path_segments(req) {
        ["clock"] ->
          mist.server_sent_events(
            req,
            response.new(200),
            init: fn() {
              let subj = process.new_subject()
              let monitor = process.monitor_process(process.self())
              let selector =
                process.new_selector()
                |> process.selecting(subj, function.identity)
                |> process.selecting_process_down(monitor, Down)
              let repeater =
                repeatedly.call(1000, Nil, fn(_state, _count) {
                  let now = system_time(Millisecond)
                  process.send(subj, Time(now))
                })
              actor.Ready(EventState(0, repeater), selector)
            },
            loop: fn(message, conn, state) {
              case message {
                Time(value) -> {
                  let event =
                    mist.event(string_builder.from_string(int.to_string(value)))
                  case mist.send_event(conn, event) {
                    Ok(_) ->
                      actor.continue(
                        EventState(..state, count: state.count + 1),
                      )
                    Error(_) -> {
                      repeatedly.stop(state.repeater)
                      actor.Stop(process.Normal)
                    }
                  }
                }
                Down(_process_down) -> {
                  repeatedly.stop(state.repeater)
                  actor.Stop(process.Normal)
                }
              }
            },
          )
        _ -> index_resp
      }
    }
    |> mist.new
    |> mist.start_http

  process.sleep_forever()
}

type Unit {
  Millisecond
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: Unit) -> Int
