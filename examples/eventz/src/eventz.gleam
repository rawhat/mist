import gleam/bytes_builder
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
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

pub fn main() {
  let index_resp =
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_builder.from_string(index_html)))

  let assert Ok(_) =
    fn(req) {
      case request.path_segments(req) {
        ["clock"] -> {
          let assert Ok(conn) =
            mist.init_server_sent_events(
              req.body,
              response.new(200)
                |> response.set_body(Nil),
            )
          let repeater =
            repeatedly.call(1000, Nil, fn(_state, _count) {
              let now = system_time(Millisecond)
              let event =
                mist.event(string_builder.from_string(int.to_string(now)))
              let assert Ok(_) = mist.send_event(conn, event)
            })

          process.sleep(30_000)

          repeatedly.stop(repeater)

          mist.end_events(conn)
        }
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
