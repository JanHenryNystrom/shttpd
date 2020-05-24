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
-module(shttpd_server_worker).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

-behaviour(gen_server).

%% Master API
-export([transfer/3]).

%% CONN API
-export([resume/1]).

%% Management API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3
        ]).

%% Includes
-include_lib("shttpd/src/shttpd_server.hrl").
-include_lib("kernel/include/logger.hrl").

%% Defines

%% Records
-record(meta, {name               :: atom(),
               protocol           :: tcp | ssl,
               state    = waiting :: waiting | prepared | active,
               server             :: #state{},
               data               :: binary(),
               socket             :: undefined | gen_tcp:socket() | ssl:socket()
              }).

%% ===================================================================
%% Master API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function:
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec transfer(pid(), binary(), #state{}) -> ok.
%%--------------------------------------------------------------------
transfer(Pid, Data, State) -> gen_server:cast(Pid, {transfer, Data, State}).


%% ===================================================================
%% CONN API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function:
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec resume(pid()) -> ok.
%%--------------------------------------------------------------------
resume(Pid) -> gen_server:cast(Pid, resume).

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
%% gen_server callbacks
%% ===================================================================

%%--------------------------------------------------------------------
-spec init(map()) -> {ok, #meta{}}.
%%--------------------------------------------------------------------
init(#{name := Name}) ->
    shttpd_server_master:enter(Name),
    {ok, #meta{name = Name}}.

%%--------------------------------------------------------------------
-spec handle_call(_, _, #meta{}) -> {noreply, #meta{}}.
%%--------------------------------------------------------------------
handle_call(Req, _, Meta) ->
    ?LOG_WARNING("Unexpected call: ~w", [Req]),
    {noreply, Meta}.

%%--------------------------------------------------------------------
-spec handle_cast(_, #meta{}) -> {noreply, #meta{}}.
%%--------------------------------------------------------------------
handle_cast({transfer, Data, State}, Meta = #meta{state = waiting}) ->
    #state{socket = Sock, protocol = Protocol} = State,
    Meta1 = Meta#meta{state = prepared,
                      server = State,
                      protocol = Protocol,
                      data = Data,
                      socket = Sock},
    {noreply, Meta1};
handle_cast(resume, Meta = #meta{state = prepared}) ->
    #meta{name = Name, server = State, data = Data} = Meta,
    Meta1 = case shttpd_server_handler:resume(Data, State) of
                #state{close = true}  ->
                    shttpd_server_master:enter(Name),
                    wait(Meta);
                State1 ->
                    active_once(Meta),
                    Meta#meta{state = active, server = State1}
            end,
    {noreply, Meta1};
handle_cast(Cast, Meta) ->
    ?LOG_WARNING("Unexpected cast: ~w", [Cast]),
    {noreply, Meta}.

%%--------------------------------------------------------------------
-spec handle_info(_, #meta{}) -> {noreply, #meta{}}.
%%--------------------------------------------------------------------
handle_info({tcp, _, Data}, Meta = #meta{state = active, server = State}) ->
    Meta1 = case shttpd_server_handler:continue(Data, State) of
                #state{close = true} ->
                    shttpd_server_master:enter(Meta#meta.name),
                    wait(Meta);
                State1 ->
                    active_once(Meta),
                    Meta#meta{server = State1}
            end,
    {noreply, Meta1};
handle_info({ssl, _, Data}, Meta = #meta{state = active, server = State}) ->
    Meta1 = case shttpd_server_handler:continue(Data, State) of
                #state{close = true} ->
                    shttpd_server_master:enter(Meta#meta.name),
                    wait(Meta);
                State1 ->
                    active_once(Meta),
                    Meta#meta{server = State1}
            end,
    {noreply, Meta1};
handle_info(Info = {Type, Sock}, Meta = #meta{state = State, socket = Sock}) ->
    Meta1 = case {Type, State} of
                {tcp_closed, active} -> wait(Meta);
                {tcp_closed, prepared} -> wait(Meta);
                {ssl_closed, active} -> wait(Meta);
                {ssl_closed, prepared} -> wait(Meta);
                _ ->
                    ?LOG_WARNING("Unexpected info: ~w", [Info]),
                    Meta
            end,
    {noreply, Meta1};
handle_info(Info = {Type, Error, Sock}, Meta = #meta{state = State}) ->
    Meta1 = case {Type, State} of
                {tcp_error, active} ->
                    ?LOG_WARNING("Socket error ~w", [Error]),
                    gen_tcp:close(Sock),
                    wait(Meta);
                {tcp_error, prepared} ->
                    ?LOG_WARNING("Socket error ~w", [Error]),
                    gen_tcp:close(Sock),
                    wait(Meta);
                {ssl_error, active} ->
                    ?LOG_WARNING("Socket error ~w", [Error]),
                    ssl:close(Sock),
                    wait(Meta);
                {ssl_error, prepared} ->
                    ?LOG_WARNING("Socket error ~w", [Error]),
                    ssl:close(Sock),
                    wait(Meta);
                _ ->
                    ?LOG_WARNING("Unexpected info: ~w", [Info]),
                    Meta
            end,
    {noreply, Meta1};
handle_info(Info, Meta) ->
    ?LOG_WARNING("Unexpected info: ~w", [Info]),
    {noreply, Meta}.

%%--------------------------------------------------------------------
-spec terminate(_, #meta{}) -> ok.
%%--------------------------------------------------------------------
terminate(_, #meta{state = waiting}) -> ok;
terminate(_, #meta{protocol = tcp, socket = Sock}) -> gen_tcp:close(Sock);
terminate(_, #meta{protocol = ssl, socket = Sock}) -> ssl:close(Sock).

%%--------------------------------------------------------------------
-spec code_change(_, #meta{}, _) -> {ok, #meta{}}.
%%--------------------------------------------------------------------
code_change(_, Meta, _) -> {ok, Meta}.

%% ===================================================================
%% Internal functions.
%% ===================================================================

active_once(#meta{protocol = tcp, socket = Sock}) ->
    inet:setopts(Sock, [{active, once}]);
active_once(#meta{protocol = ssl, socket = Sock}) ->
    ssl:setopts(Sock, [{active, once}]).

wait(Meta) -> Meta#meta{state = waiting, server = undefined}.
