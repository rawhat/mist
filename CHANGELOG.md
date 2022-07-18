# Changelog

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
