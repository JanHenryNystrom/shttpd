%% -*-erlang-*-
%%==============================================================================
%% Copyright 2020 Jan Henry Nystrom <JanHenryNystrom@gmail.com>
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

%%%-------------------------------------------------------------------
%%% @doc
%%%  Sends to the StatsD server (and when supporting TCP maintain connection)
%%% @end
%%%
%% @author Jan Henry Nystrom <JanHenryNystrom@gmail.com>
%% @copyright (C) 2020, Jan Henry Nystrom <JanHenryNystrom@gmail.com>
%%%-------------------------------------------------------------------
-module(shttpd_statsd).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

-behaviour(gen_server).

%% API
-export([timer/2, increment/1]).

%% Management API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3
        ]).

%% Includes
-include_lib("kernel/include/logger.hrl").

%% Records
-record(state, {server :: {udp,
                           ipv4 | ipv6,
                           inet:hostname() | inet:ip_address(),
                           inet:port_number()},
                socket :: gen_udp:socket()}).

%% ===================================================================
%% API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: timer(Bucket, Value) -> ok
%% @doc
%%   
%% @end
%%--------------------------------------------------------------------
-spec timer(iodata(), iodata()) -> ok.
%%--------------------------------------------------------------------
timer(Bucket, Value) -> gen_server:cast(?MODULE, {timer, Bucket, Value}).

%%--------------------------------------------------------------------
%% Function: increment(Bucket) -> ok
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec increment(iodata()) -> ok.
%%--------------------------------------------------------------------
increment(Bucket) ->
    gen_server:cast(?MODULE, {increment, Bucket}).

%% ===================================================================
%% Management API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: start_link() -> {ok, Pid}
%% @doc
%%   Starts the date-string maintainer
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.
%%--------------------------------------------------------------------
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, no_args, []).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

%%--------------------------------------------------------------------
-spec init(no_args) -> {ok, #state{}}.
%%--------------------------------------------------------------------
init(no_args) ->
    case application:get_env(shttpd,  statsd_server) of
        undefined -> {ok, #state{}};
        Server = {udp, ipv4, _, _} ->
            Sock = gen_udp:open(0, [inet]),
            {ok, #state{server = Server, socket = Sock}};
        Server = {udp, ipv6, _, _} ->
            Sock = gen_udp:open(0, [inet6]),
            {ok, #state{server = Server, socket = Sock}}
    end.

%%--------------------------------------------------------------------
-spec handle_call(_, _, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_call(Req, _, State) ->
    ?LOG_WARNING("Unexpected call: ~w", [Req]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec handle_cast(_, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_cast({timer, Bucket, Value}, State) ->
    send([Bucket/binary, $:, integer_to_binary(Value), "|ms"], State),
    {noreply, State};
handle_cast({increment, Bucket}, State) ->
    send([Bucket/binary, ":1|c"], State),
    {noreply, State};
handle_cast(Cast, State) ->
    ?LOG_WARNING("Unexpected cast: ~w", [Cast]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec handle_info(_, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected info: ~w", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec terminate(_, #state{}) -> ok.
%%--------------------------------------------------------------------
terminate(_, #state{}) -> ok.

%%--------------------------------------------------------------------
-spec code_change(_, #state{}, _) -> {ok, #state{}}.
%%--------------------------------------------------------------------
code_change(_, State, _) -> {ok, State}.

%% ===================================================================
%% Internal functions.
%% ===================================================================

send(Data, #state{socket = Sock, server = {udp, _, Host, Port}}) ->
    gen_udp:send(Sock, Host, Port, Data).


