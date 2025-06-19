# Changelog

# v5.0.0
- Refine API for starting and TLS

# v5.0.0-rc1
- Support `gleam_erlang` and `gleam_otp` v1
- Add `supervised` and `supervised_ssl` methods to help integrating with
existing supervisors
- Simply starting APIs
- Add `mist.Next` helper functions for websockets to abstract over
`gleam_otp/actor.Next` type

## v4.1.0
- Bump `stdlib` version requirement to >=0.50.0

## v4.0.7
- Tighten `gleam_http` constraint for new function

## v4.0.6
- Relaxed `gleam_http` constraint to permit v4.

## v4.0.5
- Migrate to `gleam/dynamic/decode` API

## v4.0.4
- Open files in `binary` mode to fix SSL file send bug

## v4.0.3
- Properly handle `content-length` and drop body on response when appropriate

## v4.0.2
- Replace `birl` with manual date methods (Thank you, @giacomocavalieri)

## v4.0.1
- Remove some code that produces a warning when compiling

## v4.0.0
- Bump `stdlib` version requirement to >=0.44.0

## v3.0.0
- Allow binding to an interface
- Disable IPv6 by default
- Pass `IpAddress` to `after_start`

## v2.0.0

- Return `Server` type from `start_*` methods to get OS-assigned port.  Will
also eventually provide graceful shutdown options
- Move client IP / port access from `Connection` to public function
- Don't keep HTTP/1.0 connection open
- Fix bug reading large requests from socket

## v1.2.0

- Bump gleam version requirement
- Use `erlang` application start module for clock

## v1.1.0

- Don't pull or `let assert` from websocket when more data is needed
- Don't use `uri.parse` because it's a bit slow
- Don't use the `request.set_<property>` methods, because I'm already setting
basically everything and they are kinda slow
- Support `permessage-deflate` WebSocket extension
- Pull some stuff out of `mist` into `gramps` and use its updated API
- Allow returning multiple headers with the same name
    - Currently there are no checks on which headers you do this with

## v1.0.0

- Internal API refactor along with (absolutely not ready) initial HTTP/2
"support" included but disabled
- Bumped some dependency versions
- Fix performance regression with `Date: ` header

## v1.0.0-rc2

- Second pass at Server-Sent Events
    - This API more closely follows the `gleam/otp/actor` API

## v1.0.0-rc1

- Parse `Host` header to set `host` and `port` fields on `Request`
- Bump `glisten` version
- Remove deprecated `function.compose` usage
- Support sending files over SSL
    - This does not use `sendfile` as that's not supported
    - Currently, it will naively read the whole file into memory
- Changed error type returned from `mist.start_https`
    - This now checks for the presence of the key and certificate files
- Bump `glisten` version again!
- First pass at support for Server-Sent Events

## v0.17.0

- Bump dep versions to get access to `Subject` from `glisten.serve(_ssl)`

## v0.16.0

- Updated for Gleam v0.33.0.
- Log error from `rescue` in WebSocket handlers
- WebSocket `Text` frame is now a `String`, since the spec notes that this type
  of message must be valid UTF-8

## v0.15.0

- Lots of WebSocket changes around spec correctness (still not 100% there)
- Fixed a few bugs around WebSocket handlers and user selectors

## v0.14.3

- Fix regression in WebSocket handler

## v0.14.2

- Pass scheme to `after_start` to allow building valid URLs

## v0.14.1

- Pass WebSocket state to `on_close` handler
- Fix socket active mode bug in WebSocket actor
- Update packages and change `bit_string` to `bit_array` and `bit_builder` to
  `bytes_builder`

## v0.14.0

- Remove WebSocket builder in favor of plain function
- Adds `on_init` and `on_close` to WebSocket upgrade function
- Fix an issue where websocket crashes on internal control close frame
- Upgrade to `glisten` v0.9

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
