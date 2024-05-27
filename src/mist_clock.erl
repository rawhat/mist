-module(mist_clock).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
  {ok, self()}.

stop(_State) ->
  ok.
