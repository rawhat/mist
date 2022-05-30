import gleam/option.{None, Option}
import gleam/otp/process
import glisten
import glisten/tcp

/// Helper that wraps the `glisten.serve` with no state.  If you want to just
/// write HTTP handler(s), this is what you want
pub fn serve(
  port: Int,
  handler: tcp.LoopFn(Option(process.Timer)),
) -> Result(Nil, glisten.StartError) {
  glisten.serve(port, handler, None)
}
