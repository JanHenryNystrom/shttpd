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
-module(shttpd_date).
-copyright('Jan Henry Nystrom <JanHenryNystrom@gmail.com>').

-behaviour(gen_server).

%% Includes
-include_lib("kernel/include/logger.hrl").

%% API
-export([get/0, encode/1, decode/1]).

%% Management API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3
        ]).

%% Defines
-define(SECONDS_PER_MINUTE, 60).
-define(SECONDS_PER_HOUR, 3600).
-define(SECONDS_PER_DAY, 86400).
-define(DAYS_PER_YEAR, 365).
-define(DAYS_PER_LEAP_YEAR, 366).
-define(EPOCH, 62167219200).

%% Records
-record(state, {timestamp = {{0, 0, 0}, {0, 0, 0}, 0},
                current = <<>>}).

%% ===================================================================
%% API
%% ===================================================================

%%--------------------------------------------------------------------
%% Function: get() -> Date
%% @doc
%%   Retrieves the date-string
%% @end
%%--------------------------------------------------------------------
-spec get() -> binary().
%%--------------------------------------------------------------------
get() -> ets:lookup_element(?MODULE, date, 2).

%%--------------------------------------------------------------------
%% Function: encode(Posix timestamp) -> Date
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec encode(integer()) -> binary().
%%--------------------------------------------------------------------
encode(Posix) ->
    {{Y, M, D}, {H, Mi, S}, WD} = timestamp(Posix),
    <<(weekday(WD))/binary, ", ",
      (pad(D))/binary, " ",
      (month(M))/binary, " ",
      (integer_to_binary(Y))/binary, " ",
      (pad(H))/binary, $:,
      (pad(Mi))/binary, $:,
      (pad(S))/binary, " GMT">>.

%%--------------------------------------------------------------------
%% Function: decode(Date) -> Posix timestamp
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec decode(binary()) -> integer().
%%--------------------------------------------------------------------
%% RFC1123
decode(<<_:3/binary, ", ", T/binary>>) ->
    <<Day:2/binary, $\s, Month:3/binary, $\s, Year:4/binary, $\s,
      Hour:2/binary, $:, Minute:2/binary, $:, Second:2/binary, _/binary>> = T,
    TS = #{year => binary_to_integer(Year),
           month => month_to_integer(Month),
           day => binary_to_integer(Day),
           hour => binary_to_integer(Hour),
           minute => binary_to_integer(Minute),
           second => binary_to_integer(Second)},
    timestamp:encode(TS, [posix]);
%% RFC3339
decode(RFC3339) ->
    timestamp:encode(timestamp:decode(RFC3339), [posix]).


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
start_link() -> gen_server:start_link(?MODULE, no_args, []).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

%%--------------------------------------------------------------------
-spec init(no_args) -> {ok, #state{}}.
%%--------------------------------------------------------------------
init(no_args) ->
    ets:new(?MODULE, [protected, named_table, {read_concurrency, true}]),
    tick(),
    {ok, update(#state{})}.

%%--------------------------------------------------------------------
-spec handle_call(_, _, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_call(Req, _, State) ->
    ?LOG_WARNING("Unexpected call: ~w", [Req]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec handle_cast(_, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_cast(Cast, State) ->
    ?LOG_WARNING("Unexpected cast: ~w", [Cast]),
    {noreply, State}.

%%--------------------------------------------------------------------
-spec handle_info(_, #state{}) -> {noreply, #state{}}.
%%--------------------------------------------------------------------
handle_info(tick, State) -> tick(), {noreply, update(State)};
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

update(State = #state{timestamp = Ts, current = C}) ->
    {Date = {Y, M, _}, {H, Mi, _}, _} = Ts,
    case timestamp(os:system_time(seconds)) of
        Ts -> State;
        Ts1 = {Date, {H, Mi, S1}, _} ->
            <<T:23/binary, _/bits>> = C,
            New = <<T/binary, (pad(S1))/binary, " GMT">>,
            ets:insert(?MODULE, {date, New}),
            State#state{timestamp = Ts1, current = New};
        Ts1 = {Date, {H, Mi1, S1}, _} ->
            <<T:20/binary, _/bits>> = C,
            New = <<T/binary, (pad(Mi1))/binary, $:, (pad(S1))/binary, " GMT">>,
            ets:insert(?MODULE, {date, New}),
            State#state{timestamp = Ts1, current = New};
        Ts1 = {Date, {H1, Mi1, S1}, _} ->
            <<T:17/binary, _/bits>> = C,
            New = <<T/binary,
                    (pad(H1))/binary, $:,
                    (pad(Mi1))/binary, $:,
                    (pad(S1))/binary, " GMT">>,
            ets:insert(?MODULE, {date, New}),
            State#state{timestamp = Ts1, current = New};
        Ts1 = {{Y, M, D1}, {H1, Mi1, S1}, WD1} ->
            <<_:7/binary, T:10/binary, _/bits>> = C,
            New = <<(weekday(WD1))/binary, ", ",
                    (pad(D1))/binary,
                    T/binary,
                    (pad(H1))/binary, $:,
                    (pad(Mi1))/binary, $:,
                    (pad(S1))/binary, " GMT">>,
            ets:insert(?MODULE, {date, New}),
            State#state{timestamp = Ts1, current = New};
        Ts1 = {{Y, M1, D1}, {H1, Mi1, S1}, WD1} ->
            <<_:11/binary, T:6/binary, _/bits >> = C,
            New = <<(weekday(WD1))/binary, ", ",
                    (pad(D1))/binary, " ",
                    (month(M1))/binary,
                    T/binary,
                    (pad(H1))/binary, $:,
                    (pad(Mi1))/binary, $:,
                    (pad(S1))/binary, " GMT">>,
            ets:insert(?MODULE, {date, New}),
            State#state{timestamp = Ts1, current = New};
        Ts1 = {{Y1, M1, D1}, {H1, Mi1, S1}, WD1} ->
            New = <<(weekday(WD1))/binary, ", ",
                    (pad(D1))/binary, " ",
                    (month(M1))/binary, " ",
                    (integer_to_binary(Y1))/binary, " ",
                    (pad(H1))/binary, $:,
                    (pad(Mi1))/binary, $:,
                    (pad(S1))/binary, " GMT">>,
            ets:insert(?MODULE, {date, New}),
            State#state{timestamp = Ts1, current = New}
    end.

timestamp(Posix) ->
    Secs = Posix + ?EPOCH,
    Days = Secs div ?SECONDS_PER_DAY,
    Y0 = Days div ?DAYS_PER_YEAR,
    {Y, {M, D}} =
        case year(Y0, Days, year1(Y0)) of
            {Y1, D1} when  Y1 rem 4 =:= 0, Y1 rem 100 > 0; Y1 rem 400 =:= 0 ->
                {Y1, leap_date(Days - D1)};
            {Y1, D1} ->
                {Y1, date(Days - D1)}
        end,
    Rest = Secs rem ?SECONDS_PER_DAY,
    H = Rest div ?SECONDS_PER_HOUR,
    Rest1 = Rest rem ?SECONDS_PER_HOUR,
    Mi =  Rest1 div ?SECONDS_PER_MINUTE,
    S =  Rest1 rem ?SECONDS_PER_MINUTE,
    WD = (Days+ 5) rem 7 + 1,
    {{Y, M, D}, {H, Mi, S}, WD}.

year(Y, D1, D2) when D1 < D2 -> year(Y - 1, D1, year1(Y - 1));
year(Y, _, D2) -> {Y, D2}.

year1(Y) when Y =< 0 -> 0;
year1(Y) ->
    X = Y - 1,
    X div 4 - X div 100 + X div 400 + X * ?DAYS_PER_YEAR + ?DAYS_PER_LEAP_YEAR.

date(Day) when Day < 31 -> {1, Day + 1};
date(Day) when Day < 59 -> {2, Day - 30};
date(Day) when Day < 90 -> {3, Day - 58};
date(Day) when Day < 120 -> {4, Day - 89};
date(Day) when Day < 151 -> {5, Day - 119};
date(Day) when Day < 181 -> {6, Day - 150};
date(Day) when Day < 212 -> {7, Day - 180};
date(Day) when Day < 243 -> {8, Day - 211};
date(Day) when Day < 273 -> {9, Day - 242};
date(Day) when Day < 304 -> {10,Day - 272};
date(Day) when Day < 334 -> {11,Day - 303};
date(Day) -> {12, Day - 333}.

leap_date(Day) when Day < 31 -> {1, Day + 1};
leap_date(Day) when Day < 60 -> {2, Day - 30};
leap_date(Day) when Day < 91 -> {3, Day - 59};
leap_date(Day) when Day < 121 -> {4, Day - 90};
leap_date(Day) when Day < 152 -> {5, Day - 120};
leap_date(Day) when Day < 182 -> {6, Day - 151};
leap_date(Day) when Day < 213 -> {7, Day - 181};
leap_date(Day) when Day < 244 -> {8, Day - 212};
leap_date(Day) when Day < 274 -> {9, Day - 243};
leap_date(Day) when Day < 305 -> {10,Day - 273};
leap_date(Day) when Day < 335 -> {11,Day - 304};
leap_date(Day) -> {12, Day - 334}.

pad(0) -> <<"00">>;
pad(1) -> <<"01">>;
pad(2) -> <<"02">>;
pad(3) -> <<"03">>;
pad(4) -> <<"04">>;
pad(5) -> <<"05">>;
pad(6) -> <<"06">>;
pad(7) -> <<"07">>;
pad(8) -> <<"08">>;
pad(9) -> <<"09">>;
pad(N) -> integer_to_binary(N).

weekday(1) -> <<"Mon">>;
weekday(2) -> <<"Tue">>;
weekday(3) -> <<"Wed">>;
weekday(4) -> <<"Thu">>;
weekday(5) -> <<"Fri">>;
weekday(6) -> <<"Sat">>;
weekday(7) -> <<"Sun">>.

month(1) -> <<"Jan">>;
month(2) -> <<"Feb">>;
month(3) -> <<"Mar">>;
month(4) -> <<"Apr">>;
month(5) -> <<"May">>;
month(6) -> <<"Jun">>;
month(7) -> <<"Jul">>;
month(8) -> <<"Aug">>;
month(9) -> <<"Sep">>;
month(10) -> <<"Oct">>;
month(11) -> <<"Nov">>;
month(12) -> <<"Dec">>.

month_to_integer(<<"Jan">>) -> 1;
month_to_integer(<<"Feb">>) -> 2;
month_to_integer(<<"Mar">>) -> 3;
month_to_integer(<<"Apr">>) -> 4;
month_to_integer(<<"May">>) -> 5;
month_to_integer(<<"Jun">>) -> 6;
month_to_integer(<<"Jul">>) -> 7;
month_to_integer(<<"Aug">>) -> 8;
month_to_integer(<<"Sep">>) -> 9;
month_to_integer(<<"Oct">>) -> 10;
month_to_integer(<<"Nov">>) -> 11;
month_to_integer(<<"Dec">>) -> 12.

tick() -> erlang:send_after(100, self(), tick).
