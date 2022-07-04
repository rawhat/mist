-module(http_ffi).
-export([binary_match/2, decode_packet/3, string_to_int/2]).

decode_packet(Type, Packet, Opts) ->
  case erlang:decode_packet(Type, Packet, Opts) of
    {ok, http_eoh, Rest} -> {ok, {end_of_headers, Rest}};
    {ok, Binary, Rest} -> {ok, {binary_data, Binary, Rest}};
    {more, Length} when Length =:= undefined -> {ok, {more_data, none}};
    {more, Length} -> {ok, {more_data, {some, Length}}};
    {error, Reason} -> {error, Reason}
  end.

binary_match(Source, Pattern) ->
  case binary:match(Source, Pattern) of
    {Before, After} -> {ok, {Before, After}};
    nomatch -> {error, nil}
  end.

string_to_int(String, Base) ->
  try {ok, erlang:list_to_integer(String, Base)}
  catch
    throw:badarg -> {error, nil}
  end.
