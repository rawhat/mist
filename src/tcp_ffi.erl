-module(tcp_ffi).
-export([controlling_process/2, decode_packet/3, send/2, set_opts/2]).

decode_packet(Type, Packet, Opts) ->
  case erlang:decode_packet(Type, Packet, Opts) of
    {ok, http_eoh, Rest} -> {ok, {end_of_headers, Rest}};
    {ok, Binary, Rest} -> {ok, {binary_data, Binary, Rest}};
    {more, Length} when Length =:= undefined -> {ok, {more_data, none}};
    {more, Length} -> {ok, {more_data, {some, Length}}};
    {error, Reason} -> {error, Reason}
  end.

send(Socket, Packet) ->
  case gen_tcp:send(Socket, Packet) of
    ok -> {ok, nil};
    Res -> Res
  end.

set_opts(Socket, Options) ->
  case inet:setopts(Socket, Options) of
    ok -> {ok, nil};
    {error, Reason} -> {error, Reason}
  end.

controlling_process(Socket, Pid) ->
  case gen_tcp:controlling_process(Socket, Pid) of
    ok -> {ok, nil};
    {error, Reason} -> {error, Reason}
  end.
