import glisten
import glisten/tcp
import mist/http.{State}

/// Helper that wraps the `glisten.serve` with no state.  If you want to just
/// write HTTP handler(s), this is what you want
pub fn serve(
  port: Int,
  handler: tcp.LoopFn(State),
) -> Result(Nil, glisten.StartError) {
  glisten.serve(port, handler, http.new_state())
}
