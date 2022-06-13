import gleam/bit_builder.{BitBuilder}
import gleam/http.{Header}
import gleam/http/response.{Response}
import gleam/int
import gleam/list
import gleam/map

/// Turns an HTTP response into a TCP message
pub fn to_bit_builder(resp: Response(BitBuilder)) -> BitBuilder {
  let body_size = bit_builder.byte_size(resp.body)

  let headers =
    map.from_list([#("connection", "keep-alive")])
    |> list.fold(
      resp.headers,
      _,
      fn(defaults, tup) {
        let #(key, value) = tup
        map.insert(defaults, key, value)
      },
    )

  let body_builder = case body_size {
    0 -> bit_builder.new()
    _size ->
      bit_builder.new()
      |> bit_builder.append_builder(resp.body)
      |> bit_builder.append(<<"\r\n":utf8>>)
  }

  resp.status
  |> response_builder(map.to_list(headers))
  |> bit_builder.append_builder(body_builder)
}

pub fn response_builder(status: Int, headers: List(Header)) -> BitBuilder {
  let status_string =
    status
    |> int.to_string
    |> bit_builder.from_string
    |> bit_builder.append(<<" ":utf8>>)
    |> bit_builder.append(status_to_bit_string(status))

  bit_builder.new()
  |> bit_builder.append(<<"HTTP/1.1 ":utf8>>)
  |> bit_builder.append_builder(status_string)
  |> bit_builder.append(<<"\r\n":utf8>>)
  |> bit_builder.append_builder(encode_headers(headers))
  |> bit_builder.append(<<"\r\n":utf8>>)
}

pub fn status_to_bit_string(status: Int) -> BitString {
  // Obviously nowhere near exhaustive...
  case status {
    101 -> <<"Switching Protocols":utf8>>
    200 -> <<"Ok":utf8>>
    201 -> <<"Created":utf8>>
    202 -> <<"Accepted":utf8>>
    204 -> <<"No Content":utf8>>
    301 -> <<"Moved Permanently":utf8>>
    400 -> <<"Bad Request":utf8>>
    401 -> <<"Unauthorized":utf8>>
    403 -> <<"Forbidden":utf8>>
    404 -> <<"Not Found":utf8>>
    405 -> <<"Method Not Allowed":utf8>>
    500 -> <<"Internal Server Error":utf8>>
    502 -> <<"Bad Gateway":utf8>>
    503 -> <<"Service Unavailable":utf8>>
    504 -> <<"Gateway Timeout":utf8>>
  }
}

pub fn encode_headers(headers: List(Header)) -> BitBuilder {
  list.fold(
    headers,
    bit_builder.new(),
    fn(builder, tup) {
      let #(header, value) = tup

      builder
      |> bit_builder.append_string(header)
      |> bit_builder.append(<<": ":utf8>>)
      |> bit_builder.append_string(value)
      |> bit_builder.append(<<"\r\n":utf8>>)
    },
  )
}
