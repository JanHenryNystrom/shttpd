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
%%%  
%%% @end
%%%
%% @author Jan Henry Nystrom <JanHenryNystrom@gmail.com>
%% @copyright (C) 2020, Jan Henry Nystrom <JanHenryNystrom@gmail.com>
%%%-------------------------------------------------------------------
-module(shttpd_server_conn).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

-behaviour(gen_server).

%% Management API
-export([start_link/1]).

%% Master API
-export([listen/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3
        ]).

%% Includes
-include_lib("shttpd/src/shttpd_server.hrl").
-include_lib("kernel/include/logger.hrl").

%% Defines
-define(DEFAULT, #{protocol => tcp, ssl_options => []}).
-define(TRANSFER_OPTS,
        [active, delay_send, keepalive, nodelay, priority, reuseaddr, tos]).
-define(INFINITY, -1).
-define(TIMEOUT, 5000).

%% Records

%% Types

%% ===================================================================
%% Management API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: start_link(Server) -> {ok, Pid}
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link(map()) -> {ok, pid()}.
%%--------------------------------------------------------------------
start_link(Server) -> gen_server:start_link(?MODULE, Server, []).

%% ===================================================================
%% Master API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: listen(Server, Sock) -> ok.
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec listen(pid(), gen_tcp:socket()) -> ok.
%%--------------------------------------------------------------------
listen(Pid, Sock) -> gen_server:cast(Pid, {listen, Sock}).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

%%--------------------------------------------------------------------
-spec init(map()) -> {ok, #state{}}.
%%--------------------------------------------------------------------
init(Server) ->
    #{name := Name,
      protocol := Protocol,
      routes := Routes,
      prefix_name := PrefixName,
      ssl_options := SSLOptions} = maps:merge(?DEFAULT, Server),
    System = application:get_env(shttpd,  system, <<>>),
    StatsD = case application:get_env(shttpd,  statsd_server) of
                 undefined -> false;
                 _ -> true
             end,
    LSock = shttpd_server_master:listen(Name),
    {ok, Ref} = prim_inet:async_accept(LSock, ?INFINITY),
    {ok, #state{name = Name,
                system = System,
                protocol = Protocol,
                listen_socket = LSock,
                ref = Ref,
                timeout = maps:get(timeout, Server, ?TIMEOUT),
                routes = Routes,
                prefix_name = PrefixName,
                ssl_options = SSLOptions,
                statsd_server = StatsD}}.

%%--------------------------------------------------------------------
-spec handle_call(_, _, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_call(Req, _, State) ->
    ?LOG_WARNING("Unexpected call: ~w", [Req]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec handle_cast(_, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_cast({listen, LSock}, State) ->
    {noreply, accept(State#state{listen_socket = LSock})};
handle_cast(Cast, State) ->
    ?LOG_WARNING("Unexpected cast: ~w", [Cast]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec handle_info(_, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_info({inet_async, LSock, Ref, {ok, Sock}}, State = #state{ref = Ref}) ->
    Start = erlang:system_time(milli_seconds),
    true = inet_db:register_socket(Sock, inet_tcp),
    {ok, Opts} = prim_inet:getopts(LSock, ?TRANSFER_OPTS),
    ok = prim_inet:setopts(Sock, Opts),
    StateHandle = State#state{socket = Sock,
                              start = Start,
                              limit = Start + State#state.timeout},
    shttpd_server_handler:start(StateHandle),
    {noreply, accept(State)};
handle_info({inet_async, _, Ref, Error}, State = #state{ref = Ref}) ->
    ?LOG_WARNING("inet_async error ~w", [Error]),
    {noreply, accept(State)};
handle_info(accept, State) ->
    {noreply, accept(State)};
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

accept(State = #state{listen_socket = LSock}) ->
    cancel_timer(State),
    case prim_inet:async_accept(LSock, ?INFINITY) of
        {ok, Ref} -> State#state{ref = Ref, accept_timer = undefined};
        {error, Error} ->
            ?LOG_WARNING("Socket accept failed: ~w", [Error]),
            TRef = erlang:send_after(5000, self(), accept),
            State#state{accept_timer = TRef}
    end.

cancel_timer(#state{accept_timer = undefined}) -> ok;
cancel_timer(#state{accept_timer = TRef}) -> erlang:cancel_timer(TRef).
