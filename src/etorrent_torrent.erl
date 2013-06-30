%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Maintain the torrent ETS table.
%% <p>This module is responsible for maintaining an ETS table, namely
%% the `torrent' table. This table is the general go-to place if you
%% want to know anything about a torrent and its internal state.</p>
%% <p>The code in this module is not expected to crash -- if it does,
%% it very well takes all of etorrent with it.</p>
%% <p>Also note that the module has a large number of API functions
%% you can call</p>
%% @end
%% @todo We could consider moving out the API to a separate module
-module(etorrent_torrent).

-behaviour(gen_server).

%% Counter for how many pieces is missing from this torrent
-record(c_pieces, {id :: non_neg_integer(), % Torrent id
                   missing :: non_neg_integer()}). % Number of missing pieces
%% API
-export([start_link/0,
         insert/2, all/0, statechange/2,
         num_pieces/1, decrease_not_fetched/1,
         is_seeding/1, seeding/0,
         lookup/1, get_mode/1, is_endgame/1,
         get_download_dir/1,
         is_private/1, is_paused/1]).

-export([await_entry/1]).

-export([init/1, handle_call/3, handle_cast/2, code_change/3,
         handle_info/2, terminate/2]).

%% The type of torrent records.
-type(torrent_state() :: 'leeching' | 'seeding' | 'paused' | 'unknown').
-type peer_id() :: etorrent_types:peer_id().
-type torrent_id() :: etorrent_types:torrent_id().

%% A single torrent is represented as the 'torrent' record
%% TODO: How many seeders/leechers are we connected to?
-record(torrent,
	{ %% Unique identifier of torrent, monotonically increasing
          id :: non_neg_integer(),
          %% How many bytes are there left before we stop.
          %% Only valid (i.e. stored AND checked) pieces are counted.
          left = unknown :: unknown | non_neg_integer(),
          display_name :: string(),
          %% The number of bytes this client still has to download. 
          %% Clarification: The number of bytes needed to download to be 
          %% 100% complete and get all the included files in the torrent.
          left_or_skipped = unknown :: unknown | non_neg_integer(),
          %% How many bytes are there in total
          total  :: non_neg_integer(),
          %% How many bytes we want from this torrent (both downloaded and not yet)
          wanted :: non_neg_integer(),
          %% How many bytes have we uploaded
          uploaded :: non_neg_integer(),
          %% How many bytes have we downloaded
          downloaded :: non_neg_integer(),
          %% Uploaded and downloaded bytes, all time
          all_time_uploaded = 0 :: non_neg_integer(),
          all_time_downloaded = 0 :: non_neg_integer(),
          %% Number of pieces in torrent
          pieces = unknown :: non_neg_integer() | 'unknown',
          %% How many people have a completed file?
          %% `complete' field from the tracker responce.
          seeders = 0 :: non_neg_integer(),
          %% How many people are downloaded
          %% `incomplete' field from the tracker responce.
          leechers = 0 :: non_neg_integer(),
          connected_seeders = 0 :: non_neg_integer(),
          connected_leechers = 0 :: non_neg_integer(),
          %% This is a list of recent speeds present so we can plot them
          rate_sparkline = [0.0] :: [float()],
          %% BEP 27: is this torrent private
          is_private :: boolean(),
          %% A rewritten local peer id for this torrent.
          peer_id :: peer_id() | undefined,
          %% A rewritten target directory (download_dir).
          directory :: file:filename() | undefined,
          mode :: progress | endgame,
          state :: torrent_state(),
          is_paused = false :: boolean(),
          is_partial = false:: boolean()}).

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).
-record(state, { monitoring :: dict() }).

%% ====================================================================

%% @doc Start the `gen_server' governor.
%% @end
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Initialize a torrent
%% <p>The torrent entry for Id with the tracker
%%   state as given. Pieces is the number of pieces for this torrent.
%% </p>
%% <p><emph>Precondition:</emph> The #piece table has been filled with the torrents pieces.</p>

%%  Info is a proplist:
%%
%%  ```
%% [{uploaded, integer()},
%%  {downloaded, integer()},
%%  {all_time_uploaded, non_neg_integer()},
%%  {all_time_downloaded, non_neg_integer()},
%%  {left, integer()},
%%  {total, integer()},
%%  {is_private, boolean()},
%%  {pieces, integer()},
%%  {missing, integer()},
%%  {state, atom()}]
%% '''
%%
%% @end
-spec insert(integer(), [{atom(), term()}]) -> ok.
insert(Id, PL) ->
    T = props_to_record(Id, PL),

    Missing = proplists:get_value(missing, PL),
    P = #c_pieces{ id = Id, missing = Missing},

    gen_server:call(?SERVER, {insert, Id, T, P}).


%% @doc Return all torrents, sorted by Id
%% @end
-spec all() -> [[{term(), term()}]].
all() ->
    all(#torrent.id).

%% @doc Request a change of state for the torrent
%% <p>The specific What part is documented as the alteration() type
%% in the module.
%% </p>
%% @end
-type alteration() :: unknown
                    | endgame
                    | paused
                    | continue
                    | {add_downloaded, integer()}
                    | {add_upload, integer()}
                    | {subtract_left, integer()}
                    | {subtract_left_or_skipped, integer()}
                    | {tracker_report, integer(), integer()}
                    | {set_wanted, non_neg_integer()}
                    | {set_peer_id, peer_id()}.
-spec statechange(integer(), [alteration()]) -> ok.
statechange(Id, What) ->
    gen_server:cast(?SERVER, {statechange, Id, What}).

%% @doc Return the number of pieces for torrent Id
%% @end
-spec num_pieces(integer()) -> {value, integer()} | not_found.
num_pieces(Id) ->
    gen_server:call(?SERVER, {num_pieces, Id}).

%% @doc Return a property list of the torrent identified by Id
%% @end
-spec lookup(integer()) ->
		    not_found | {value, [{term(), term()}]}.
lookup(Id) ->
    case ets:lookup(?TAB, Id) of
	[] -> not_found;
	[M] -> {value, proplistify(M)}
    end.

-spec await_entry(Id :: torrent_id()) -> ok.
await_entry(Id) ->
    await_entry(Id, 8, 500).

await_entry(_Id, 0, _Timeout) ->
    {error, not_found};
await_entry(Id, N, Timeout) when N > 0 ->
    case ets:member(?TAB, Id) of
        false -> timer:sleep(Timeout), await_entry(Id, N-1, Timeout);
        true  -> ok
    end.

%% @doc Returns true if the torrent is a seeding torrent
%% @end
-spec is_seeding(integer()) -> boolean().
is_seeding(Id) ->
    case ets:lookup(?TAB, Id) of
	[#torrent{state=State}] -> State =:= seeding
    end.

%% @doc Returns all torrents which are currently seeding
%% @end
-spec seeding() -> {value, [integer()]}.
seeding() ->
    Torrents = all(),
    {value, [proplists:get_value(id, T) ||
		T <- Torrents,
		proplists:get_value(state, T) =:= seeding]}.

%% @doc Track that we downloaded a piece
%%  <p>As a side-effect, this call eventually updates the endgame state</p>
%% @end
-spec decrease_not_fetched(integer()) -> ok.
decrease_not_fetched(Id) ->
    gen_server:call(?SERVER, {decrease, Id}).


-spec get_mode(torrent_id()) -> boolean().
get_mode(Id) ->
    case ets:lookup(?TAB, Id) of
        [T] -> T#torrent.mode;
        [] -> undefined % The torrent isn't there anymore.
    end.


-spec get_download_dir(torrent_id()) -> file:filename().
get_download_dir(Id) ->
    [T] = ets:lookup(?TAB, Id),
    case T#torrent.directory of
        undefined -> etorrent_config:download_dir();
        D -> D
    end.


%% @doc Returns true if the torrent is in endgame mode
%% @end
%% TODO: checkme
-spec is_endgame(integer()) -> boolean().
is_endgame(Id) ->
    case ets:lookup(?TAB, Id) of
        [T] -> T#torrent.mode =:= endgame;
        [] -> false % The torrent isn't there anymore.
    end.
    
%% @doc Returns true if the torrent is private.
%% @end
-spec is_private(integer()) -> boolean().
is_private(Id) ->
    case ets:lookup(?TAB, Id) of
        [T] -> T#torrent.is_private;
        [] -> false
    end.

-spec is_paused(integer()) -> boolean().
is_paused(Id) ->
    case ets:lookup(?TAB, Id) of
        [T] -> T#torrent.is_paused;
        [] -> false
    end.

%% =======================================================================

%% @private
init([]) ->
    _ = ets:new(?TAB, [protected, named_table, {keypos, #torrent.id}]),
    _ = ets:new(etorrent_c_pieces, [protected, named_table,
                                    {keypos, #c_pieces.id}]),
    erlang:send_after(timer:seconds(60),
		      self(),
		      rate_sparkline_update),
    {ok, #state{ monitoring = dict:new() }}.


%% @private
%% @todo Avoid downs. Let the called process die.
handle_call({insert, Id, T=#torrent{}, P=#c_pieces{}},  {Pid, _Tag},  S) ->
    case ets:member(?TAB, Id) of
        false ->
            true = ets:insert_new(?TAB, T),
            true = ets:insert_new(etorrent_c_pieces,  P),

            R = erlang:monitor(process, Pid),
            NS = S#state { monitoring = dict:store(R, Id, S#state.monitoring) },
            {reply, ok, NS};
        true  ->
            %% Just replace.
            true = ets:insert(?TAB, T),
            true = ets:insert(etorrent_c_pieces,  P),
            {reply, ok, S}
    end;

handle_call({num_pieces, Id}, _F, S) ->
    Reply = case ets:lookup(?TAB, Id) of
		[R] -> {value, R#torrent.pieces};
		[] ->  not_found
	    end,
    {reply, Reply, S};

handle_call({decrease, Id}, _F, S) ->
    N = ets:update_counter(etorrent_c_pieces, Id, {#c_pieces.missing, -1}),
    case N of
        0 ->
            state_change(Id, [endgame]),
            {reply, endgame, S};
        N when is_integer(N) ->
            {reply, ok, S}
    end;

handle_call(_M, _F, S) ->
    {noreply, S}.


%% @private
handle_cast({statechange, Id, What}, S) ->
    state_change(Id, What),
    {noreply, S};

handle_cast(_Msg, S) ->
    {noreply, S}.


%% @private
handle_info({'DOWN', Ref, _, _, _}, S) ->
    {ok, Id} = dict:find(Ref, S#state.monitoring),
    ets:delete(?TAB, Id),
    ets:delete(etorrent_c_pieces, Id),
    {noreply, S#state { monitoring = dict:erase(Ref, S#state.monitoring) }};

handle_info(rate_sparkline_update, S) ->
    for_each_torrent(fun update_sparkline_rate/1),
    erlang:send_after(timer:seconds(60), self(), rate_sparkline_update),
    {noreply, S};

handle_info(_M, S) ->
    {noreply, S}.


%% @private
code_change(_OldVsn, S, _Extra) ->
    {ok, S}.


%% @private
terminate(_Reason, _S) ->
    ok.


%% -----------------------------------------------------------------------


props_to_record(Id, PL) ->
    FU = fun(Key) -> proplists:get_value(Key, PL) end,

    % Read optional value. 
    % If it is undefined then use default value.
    FO = fun(Key, Def) -> proplists:get_value(Key, PL, Def) end,

    % Read required value.
    FR = fun(Key) -> 
            case proplists:get_value(Key, PL) of
            X when (X =/= undefined) -> X
            end
        end,

    L = FR(left),
    LS = FO(left_or_skipped, L),

    % If the `state' is `undefined' or `unknown' then use the default state.
    State = case FO('state', 'unknown') of
            'unknown' ->
                left_to_state(L, LS);

            X -> X
        end,

    Total = FR('total'),
    #torrent { id = Id,
               display_name = FU(display_name),
               left = L,
               left_or_skipped = LS,
               total = Total,
               wanted = FO(wanted, Total),
               uploaded = FO('uploaded', 0),
               downloaded = FO('downloaded', 0),
			   all_time_uploaded = FO('all_time_uploaded', 0),
			   all_time_downloaded = FO('all_time_downloaded', 0),
               pieces = FO(pieces, 'unknown'),
               is_private = FR(is_private),
               is_paused = FO(is_paused, false),
               is_partial = FO(is_partial, false),
               peer_id = FU(peer_id),
               directory = FU(directory),
               state = State,
               mode = FO(mode, progress)
             }.


%%--------------------------------------------------------------------
%% Function: all(Pos) -> Rows
%% Description: Return all torrents, sorted by Pos
%%--------------------------------------------------------------------
all(Pos) ->
    Objects = ets:match_object(?TAB, '$1'),
    lists:keysort(Pos, Objects),
    [proplistify(O) || O <- Objects].

proplistify(T) ->
    OptionalPairs =
    [{peer_id,          T#torrent.peer_id},
     {directory,        T#torrent.directory}],

    skip_undefined(OptionalPairs) ++
    [{id,               T#torrent.id},
     {display_name,     T#torrent.display_name},
     {is_private,       T#torrent.is_private},
     {total,            T#torrent.total},
     {wanted,           T#torrent.wanted},
     {left,             T#torrent.left},
     {left_or_skipped,  T#torrent.left_or_skipped},
     {uploaded,         T#torrent.uploaded},
     {downloaded,       T#torrent.downloaded},
     {all_time_downloaded, T#torrent.all_time_downloaded},
     {all_time_uploaded,   T#torrent.all_time_uploaded},
     {leechers,         T#torrent.leechers},
     {seeders,          T#torrent.seeders},
     {connected_leechers, T#torrent.connected_leechers},
     {connected_seeders,  T#torrent.connected_seeders},
     {state,            T#torrent.state},
     {mode,             T#torrent.mode},
     {rate_sparkline,   T#torrent.rate_sparkline},
     {is_paused,        T#torrent.is_paused},
     {is_partial,       T#torrent.wanted =/= T#torrent.total}].


%% @doc Run function F on each torrent
%% @end
for_each_torrent(F) ->
    Objects = ets:match_object(?TAB, '$1'),
    lists:foreach(F, Objects).

%% @doc Update the rate_sparkline field in the #torrent{} record.
%% @end
update_sparkline_rate(Row) ->
    case Row#torrent.state of
        X when X =:= seeding orelse X =:= leeching ->
            {ok, R} = etorrent_peer_states:get_torrent_rate(
                            Row#torrent.id, X),
            SL = update_sparkline(R, Row#torrent.rate_sparkline),
            ets:insert(?TAB, Row#torrent { rate_sparkline = SL }),
            ok;
        _ ->
            ok
    end.

%% @doc Add a new rate to a sparkline, and trim if it gets too big
%% @end
update_sparkline(NR, L) ->
    case length(L) > 25 of
        true ->
            {F, _} = lists:split(20, L),
            [NR | F];
        false ->
            [NR | L]
    end.


%% Change the state of the torrent with Id, altering it by the "What" part.
%% Precondition: Torrent exists in the ETS table.
state_change(Id, List) when is_integer(Id) ->
    case ets:lookup(?TAB, Id) of
        [T] ->
            try
                NewT = do_state_change(List, T),
                ets:insert(?TAB, NewT),

                case {T#torrent.state, NewT#torrent.state} of
                    {leeching, seeding} ->
                        etorrent_event:seeding_torrent(Id),
                        ok;
                    _ ->
                        ok
                end
            catch error:Reason ->
                lager:error("state_change failed with ~p.", [Reason]),
                {error, failed}
            end;
        []   ->
            %% This is protection against bad torrent ids.
            lager:error("Not found ~p, skip.", [Id]),
            {error, not_found}
    end.


do_state_change([unknown | Rem], T) ->
    do_state_change(Rem, T#torrent{state = unknown});

do_state_change([{set_mode, Mode} | Rem], T) ->
    do_state_change(Rem, T#torrent{mode = Mode});

do_state_change([{is_paused, X} | Rem], T) when is_boolean(X) ->
    do_state_change(Rem, T#torrent{is_paused = X});

do_state_change([paused | Rem], T) ->
    do_state_change(Rem, T#torrent{state = paused, is_paused = true});

do_state_change([continue | Rem], T) ->
    NewState = left_to_state(T#torrent.left, T#torrent.left_or_skipped),
    do_state_change(Rem, T#torrent{state = NewState, is_paused = false});

do_state_change([checking | Rem], T=#torrent{wanted=Wanted, total=Total}) ->
    do_state_change(Rem, T#torrent{state = checking,
                                   left = Wanted,
                                   left_or_skipped = Total});

do_state_change([waiting | Rem], T) ->
    do_state_change(Rem, T#torrent{state = waiting});

do_state_change([{add_downloaded, Amount} | Rem], T) ->
    NewT = T#torrent{downloaded = T#torrent.downloaded + Amount},
    do_state_change(Rem, NewT);

do_state_change([{add_upload, Amount} | Rem], T) ->
    NewT = T#torrent{uploaded = T#torrent.uploaded + Amount},
    do_state_change(Rem, NewT);

do_state_change([{subtract_left, Amount} | Rem], T) ->
    #torrent{id=Id, state=OldState, left=OldLeft, is_partial=IsPartial} = T,
    Left = OldLeft - Amount,

    NewT = case Left of
        0 ->
	        ControlPid = etorrent_torrent_ctl:lookup_server(Id),
			etorrent_torrent_ctl:completed(ControlPid),
            lager:debug("IsPartial is ~p.", [IsPartial]),
            T#torrent {
                left = 0, 
                state = if OldState =:= paused -> paused;
                           IsPartial           -> partial;
                           true                -> seeding
                        end,
                rate_sparkline = [0.0] };

        N when OldLeft =:= 0, OldState =:= partial ->
           %% partial => leeching
           T#torrent { left = N, state = leeching };

        N when N =< T#torrent.total ->
           T#torrent { left = N }
        end,

    case {OldState, NewT#torrent.state} of
        {X, X} -> ok;
        {OldState, NewState} ->
            lager:debug("~p changed its state from ~p to ~p.",
                        [Id, OldState, NewState])
    end,

    do_state_change(Rem, NewT);

do_state_change([{subtract_left_or_skipped, Amount} | Rem], T) ->
    Left = T#torrent.left_or_skipped - Amount,
    NewT = T#torrent { left_or_skipped = Left },
    do_state_change(Rem, NewT);

do_state_change([{set_wanted, Amount} | Rem], T=#torrent{total=Total})
    when is_integer(Amount), Amount >= 0 ->
    NewT = T#torrent { wanted = Amount, is_partial=Amount =/= Total },
    do_state_change(Rem, NewT);

do_state_change([{set_peer_id, PeerId} | Rem], T) ->
    NewT = T#torrent { peer_id = PeerId },
    do_state_change(Rem, NewT);

do_state_change([{set_directory, Dir} | Rem], T) ->
    NewT = T#torrent { directory = Dir },
    do_state_change(Rem, NewT);
    
do_state_change([{tracker_report, Seeders, Leechers} | Rem], T) ->
    NewT = T#torrent{seeders = Seeders, leechers = Leechers},
    do_state_change(Rem, NewT);

do_state_change([inc_connected_leecher | Rem], T=#torrent{connected_leechers=L}) ->
    NewT = T#torrent{connected_leechers=L+1},
    do_state_change(Rem, NewT);

do_state_change([dec_connected_leecher | Rem], T=#torrent{connected_leechers=L}) ->
    NewT = T#torrent{connected_leechers=L-1},
    do_state_change(Rem, NewT);

do_state_change([inc_connected_seeder | Rem], T=#torrent{connected_seeders=L}) ->
    NewT = T#torrent{connected_seeders=L+1},
    do_state_change(Rem, NewT);

do_state_change([dec_connected_seeder | Rem], T=#torrent{connected_seeders=L}) ->
    NewT = T#torrent{connected_seeders=L-1},
    do_state_change(Rem, NewT);

do_state_change([], T) ->
    T.




left_to_state(L, LS) ->
    if L =:= 0, LS =:= 0 -> seeding;
       L =:= 0, LS =/= 0 -> partial; %% partial seeding
                    true -> leeching
    end.

skip_undefined(Pairs) ->
    [{K,V} || {K,V} <- Pairs, V =/= undefined].
