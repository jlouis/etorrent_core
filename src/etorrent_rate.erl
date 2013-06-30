%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail>
%% @doc Measure the rate of a connection
%% <p>The rate module can measure the current rate of a connection by
%% using a sliding window protocol on top of updates.</p>
%% <p>You can initialize a new rate object with {@link init/0} after
%% which you can subsequently update it by calling {@link
%% update/2}. Each update will track the amount of bytes that has been
%% downloaded and use a 20 second sliding window to interpolate the
%% rate. The advantage of this solution is that small fluctuations
%% will not affect the rate and since it is effectively a running
%% average over the 20 seconds.</p>
%% @end
-module(etorrent_rate).

%% API
-export([init/0, init/1, update/2, format_eta/2]).

-include("etorrent_rate.hrl").

-type rate() :: #peer_rate{}.
-export_type([rate/0]).

-define(MAX_RATE_PERIOD, 20).

%% ====================================================================

%% @doc Convenience initializer for {@link init/1}
%% @end
init() -> init(?RATE_FUDGE).

%% @doc Initialize the rate tuple.
%% <p>Takes a single integer, fudge, which is the fudge factor used to start up.
%% It fakes the startup of the rate calculation.</p>
%% @end
-spec init(integer()) -> #peer_rate{}.
init(Fudge) ->
    T = now_secs(),
    #peer_rate { next_expected = T + Fudge,
                 last = T - Fudge,
                 rate_since = T - Fudge }.

%% @doc Update the rate record with Amount new downloaded bytes
%% @end
-spec update(#peer_rate{}, integer()) -> #peer_rate{}.
update(#peer_rate {rate = Rate,
                   total = Total,
                   next_expected = NextExpected,
                   last = Last,
                   rate_since = RateSince} = RT, Amount) when is_integer(Amount) ->
    T = now_secs(),
    case T < NextExpected andalso Amount =:= 0 of
        true ->
            %% We got 0 bytes, but we did not expect them yet, so just
            %% return the current tuple (simplification candidate)
            RT;
        false ->
            %% New rate: Timeslot between Last and RateSince contributes
            %%   with the old rate. Then we add the new Amount and calc.
            %%   the rate for the interval [T, RateSince].
            R = (Rate * (Last - RateSince) + Amount) / (T - RateSince),
            #peer_rate { rate = R, %% New Rate
                         total = Total + Amount,
                         %% We expect the next data-block at the minimum of 5 secs or
                         %%   when Amount bytes has been fetched at the current rate.
                         next_expected = T + min(5, Amount / max(R, 0.0001)),
                         last = T,
                         %% RateSince is manipulated so it does not go beyond
                         %% ?MAX_RATE_PERIOD
                         rate_since = max(RateSince, T - ?MAX_RATE_PERIOD)}
    end.

%% @doc Calculate estimated time of arrival.
%% @end
-type eta() :: {integer(), {integer(), integer(), integer()}}.
-spec eta(integer(), float()) -> eta() | unknown.
eta(_Left, DR) when DR == 0 ->
    unknown;
eta(Left, DownloadRate) when is_integer(Left) ->
    calendar:seconds_to_daystime(round(Left / DownloadRate));
eta(unknown, _DownloadRate) ->
    unknown.

%% @doc Format an ETA given bytes Left and a Rate
%% <p>This function will return an iolist() format of the ETA given
%% how many bytes there are `Left' to download and the current `DownloadRate'.
%% </p>
%% @end
-spec format_eta(integer(), float()) -> iolist().
format_eta(Left, DownloadRate) ->
    case eta(Left, DownloadRate) of
	{DaysLeft, {HoursLeft, MinutesLeft, SecondsLeft}} ->
	    io_lib:format("ETA: ~Bd ~Bh ~Bm ~Bs",
			  [DaysLeft, HoursLeft, MinutesLeft, SecondsLeft]);
	unknown ->
	    "ETA: Unknown"
    end.

% @doc Returns the number of seconds elapsed as gregorian calendar seconds
% @end
-spec now_secs() -> integer().
now_secs() ->
    {Mega, Sec, _Micro} = os:timestamp(),
    Mega * 1000000 + Sec.
%   calendar:datetime_to_gregorian_seconds(calendar:local_time()).
