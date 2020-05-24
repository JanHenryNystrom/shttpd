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
-module(shttpd_server_master).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

-behaviour(gen_server).

%% Worker API
-export([enter/1, listen/1]).

%% API
-export([transfer/3]).

%% Management API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3
        ]).

%% Includes
-include_lib("kernel/include/logger.hrl").

%% Defines
-define(LISTEN_OPTS, [binary,
                      {packet, raw},
                      {active, false},
                      {reuseaddr, true},
                      {keepalive, true}]).

%% Records
-record(state, {parent :: pid(),
                listen_socket :: gen_tcp:socket(),
                ip :: inet:address(),
                port :: integer(),
                workers = [] :: [pid()]}).

%% ===================================================================
%% Worker API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function:
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec enter(atom()) -> ok.
%%--------------------------------------------------------------------
enter(Name) ->
    link(whereis(Name)),
    gen_server:cast(Name, {enter, self()}).

%%--------------------------------------------------------------------
%% Function:
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec listen(atom()) -> ok.
%%--------------------------------------------------------------------
listen(Name) -> gen_server:call(Name, listen).


%% ===================================================================
%% API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: transfer(Name, Data, State) -> {ok, Pid} | false
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec transfer(atom(), binary(), tuple()) -> {ok, pid()} | false.
%%--------------------------------------------------------------------
transfer(Name, Data, ServerState) ->
    gen_server:call(Name, {transfer, Data, ServerState}).

%% ===================================================================
%% Management API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: start_link(Parent, Map) -> {ok, Pid}
%% @doc
%%   Starts the cowboy controlling server.
%% @end
%%--------------------------------------------------------------------
-spec start_link(pid(), map()) -> {ok, pid()}.
%%--------------------------------------------------------------------
start_link(Parent, Server = #{name := Name}) ->
    gen_server:start_link({local, Name}, ?MODULE, {Parent, Server}, []).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

%%--------------------------------------------------------------------
-spec init(map()) -> {ok, #state{}}.
%%--------------------------------------------------------------------
init({Parent, Map}) ->
    #{prefix_name := PrefixName, ip := IP, port := Port, routes :=Routes} = Map,
    process_flag(trap_exit, true),
    {ok, LSock} = gen_tcp:listen(Port, [{ip, IP} | ?LISTEN_OPTS]),
    shttpd_prefix:load(PrefixName, Routes),
    {ok, #state{parent = Parent, ip = IP, port = Port, listen_socket = LSock}}.

%%--------------------------------------------------------------------
-spec handle_call(_, _, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_call(listen, _, State = #state{listen_socket = LSock}) ->
    {reply, LSock, State};
handle_call({transfer, _, _}, _, State = #state{workers = []}) ->
    {reply, false, State};
handle_call(Trans = {transfer, _, _}, _, State = #state{workers = [H|T]}) ->
    {transfer, Data, ServerState} = Trans,
    shttpd_server_worker:transfer(H, Data, ServerState),
    {reply, {ok, H}, State#state{workers = T}};
handle_call(Req, _, State) ->
    ?LOG_WARNING("Unexpected call: ~w", [Req]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec handle_cast(_, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_cast({enter, Pid}, State = #state{workers = Ws}) ->
    {noreply, State#state{workers = [Pid | Ws]}};
handle_cast(Cast, State) ->
    ?LOG_WARNING("Unexpected cast: ~w", [Cast]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec handle_info(_, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_info({tcp_closed, LSock}, State = #state{listen_socket = LSock}) ->
    #state{ip = IP, port = Port, parent = Parent} = State,
    case gen_tcp:listen(Port, [{ip, IP} | ?LISTEN_OPTS]) of
        {ok, LSock1} ->
            [shttpd_server_conn:listen(C, LSock1) ||
                C <- shttpd_server_sup:conns(Parent)],
            {noreply, State#state{listen_socket = LSock1}};
        {error, Error} ->
            {stop, {closed, Error}}
    end;
handle_info({tcp_error, LSock, Reason}, State = #state{listen_socket=LSock}) ->
    #state{ip = IP, port = Port, parent = Parent} = State,
    gen_tcp:close(LSock),
    case gen_tcp:listen(Port, [{ip, IP} | ?LISTEN_OPTS]) of
        {ok, LSock1} ->
            [shttpd_server_conn:listen(C, LSock1) ||
                C <- shttpd_server_sup:conns(Parent)],
            {noreply, State#state{listen_socket = LSock1}};
        {error, Error} ->
            {stop, {error, Error, Reason}}
    end;
handle_info({'EXIT', Pid, _}, State = #state{workers = Ws}) ->
    {noreply, State#state{workers = lists:delete(Pid, Ws)}};
handle_info(Info, State) ->
    ?LOG_WARNING("Unexpected info: ~w", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec terminate(_, #state{}) -> ok.
%%--------------------------------------------------------------------
terminate(_, #state{listen_socket = Sock}) -> gen_tcp:close(Sock).

%%--------------------------------------------------------------------
-spec code_change(_, #state{}, _) -> {ok, #state{}}.
%%--------------------------------------------------------------------
code_change(_, State, _) -> {ok, State}.

%% ===================================================================
%% Internal functions.
%% ===================================================================
