# Changelog

## Unreleased

- Remove WebSocket builder in favor of plain function
- Adds `on_init` and `on_close` to WebSocket upgrade function
- Fix an issue where websocket crashes on internal control close frame

## v0.13.2

- Upgrade `glisten` and `gleam_otp` versions

## v0.13.1

- Improve file sending ergonomics

## v0.13.0

- Big API refactor
- Add `client_ip` to `Connection` construct
- Fix reading chunked encoding
- Add method for streaming request body

## v0.12.0

- Correctly handle query strings (@Johann150)
- Add constructor for opaque `Body` type for testing handlers
- Handle WebSocket `ping` frames and reply correctly
- Fix incorrect pattern match in `file_open` (@avdgaag)

## v0.11.0

- Big public API refactoring and docs clean-up
- Fixed erroneous extra CRLF after response body

## v0.10.0

- Support chunked responses, via `Chunked(Iterator(BitBuilder))`
- Convert syntax for gleam v0.27 support

## v0.9.4

- Utilize `request.scheme` to determine which transport to use automatically
- Support the `Expect: 100-continue` header functionality

## v0.9.3

- Remove duplicate imports that errored on newer gleam versions

## v0.9.2

- Support more HTTP status codes

## v0.9.1

- Allow `state.transport` in handlers to abstract over `TCP`/`SSL`

## v0.9.0

- Add SSL support via the `run_service_ssl` and `serve_ssl` methods
- Some refactorings in the internal libraries, if you were depending on them

## v0.8.3

- Update `glisten` version

## v0.8.2

- Fixed up broken README examples

## v0.8.1

- Removed a `main` method I accidentally left in :(

## v0.8.0

- BREAKING:
  - refactor `http.handle` and `http.handle_func` into separate module

The `handler_func` implementation was about 250 lines. That seemed a little
excessive and unclear, so I just pulled that stuff out into separate functions.
I also thought it might be nice to have a separate `handler` module that housed
this code. The actual consumer changes are minimal.

## v0.7.1

- Revert `websocket.send` change
  - It should be a similar order to `process.send`

## v0.7.0

- Stop automatically reading body
  - `run_service` now accepts maximum body size
  - `http` module exports `read_body` to manually parse body
- Support `Transfer-Encoding: chunked` requests
- Properly support query parameters

## v0.6.1

- Fix `websocket.send` argument order
- Bump GitHub workflow versions

## v0.6.0

- Big WebSocket changes
  - Handle larger text messages
  - Support binary messages
  - Properly reply to `ping` messages
  - Add helper function for `send`ing

## v0.5.2

- Properly support (most) HTTP methods

## v0.5.1

- Use `Sender` in WS handler instead of raw socket

## v0.5.0

- Bump `glisten` version
- Add support for `on_init` and `on_close` events on WebSockets

## v0.4.5

- Make sure to include `"content-length"` header

## v0.4.4

- Wrap user handler function in `rescue` call
- Add `logger` support for error handling

## v0.4.3

- Remove default `"content-type"` header guessing
- Add `run_service` method for simple servers

## v0.4.2

- Update some handler response type names

## v0.4.1

- Support for sending files with `file:sendfile`

## v0.4.0

- Remove `router` module and move to `http`

## Note

I started this list way later and don't really feel like going back further
than this.
