%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Choose which peers to download from / upload to.
%% <p>The choking module is responsible for performing choking
%% operations every 10 seconds. It queries the current state of all
%% peers and subsequently chokes/unchokes peers according to the
%% choking algorithm.</p>
%% <p>The choking algorithm is probably the nastiest part of the
%% BitTorrent protocol. Several things are taken into consideration,
%% including download speed, upload speed, interest and if the peer is
%% choking us or not.</p>
%% @end
-module(etorrent_choker).

-behaviour(gen_server).


%% API
-export([start_link/0,
         perform_rechoke/0,
         monitor/1,
         set_upload_slots/2,
         set_round_time/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {info_hash = none   :: none | binary(),
                round = 0          :: integer(),
                optimistic_unchoke_pid = none :: none | pid(),
                opt_unchoke_chain = [] :: [pid()],
                min_upload_slots :: non_neg_integer(),
                max_upload_slots :: non_neg_integer(),
                round_time = 10000 :: timeout(),
                round_tref :: reference()
               }).

-record(rechoke_info, {pid :: pid(),
                       %% Peers state:
                       peer_state :: 'seeding' | 'leeching',
                       %% Our state:
                       state :: 'seeding' | 'leeching' ,
                       peer_snubs :: boolean(),
                       r_interest_state :: 'interested' | 'not_interested',
                       r_choke_state :: 'choked' | 'unchoked' ,
                       l_choke :: boolean(),
                       rate :: float() }).

-define(SERVER, ?MODULE).


%%====================================================================

%% @doc Start the choking server.
%% @end
-spec start_link() -> {ok, pid()} | {error, any()} | ignore.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Request an immediate rechoke rather than wait.
%% <p>This call is used when something urgent happens where it would
%% be advantageous to quickly rechoke all peers.</p>
%% @end
-spec perform_rechoke() -> ok.
perform_rechoke() ->
    gen_server:cast(?SERVER, rechoke).

%% @doc Ask the choking server to monitor `Pid'
%% @end
-spec monitor(pid()) -> ok.
monitor(Pid) ->
    gen_server:call(?SERVER, {monitor, Pid}).

set_upload_slots(MinUploadSlots, MaxUploadSlots) ->
    gen_server:call(?SERVER, {set_upload_slots, MinUploadSlots, MaxUploadSlots}).

set_round_time(RoundTime) ->
    gen_server:call(?SERVER, {set_round_time, RoundTime}).

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

rechoke(Chain, #state{min_upload_slots=MinUploadSlots,
                      max_upload_slots=MaxUploadSlots}) ->
    rechoke(Chain, MinUploadSlots, MaxUploadSlots).

%% @doc Recalculate the choke/unchoke state of peers.
%% @end
rechoke(Chain, MinUploadSlots, MaxUploadSlots) ->
    Peers = build_rechoke_info(Chain),
    {PreferredDown, PreferredSeed} = split_preferred(Peers),
    PreferredSet = find_preferred_peers(PreferredDown, PreferredSeed, MaxUploadSlots),
    PSetSize = sets:size(PreferredSet),
    OptSlots = optimistics(PSetSize, MinUploadSlots, MaxUploadSlots),
    lager:info("Rechoke. Min=~p, max=~p, opt=~p, pref=~p.",
               [MinUploadSlots, MaxUploadSlots, OptSlots, PSetSize]),
    ToChoke = rechoke_unchoke(Peers, PreferredSet),
    rechoke_choke(ToChoke, 0, OptSlots).

optimistics(PSetSize, MinUploadSlots, MaxUploadSlots) ->
    max(MinUploadSlots, MaxUploadSlots - PSetSize).


%% Upload slot calculation
calc_max_upload_slots() ->
    case etorrent_config:max_upload_slots() of
        auto ->
            Rate = etorrent_config:max_upload_rate(),
            case Rate of
                N when N =<  0 -> 7; %% Educated guess
                N when N  <  9 -> 2;
                N when N  < 15 -> 3;
                N when N  < 42 -> 4;
                N ->
                    round(math:sqrt(N * 0.8))
            end;
        N when is_integer(N) ->
            N
    end.


%% TODO: It is not per se given that this function belongs here. It is
%% a view on a peer, which tells us the given current state and the given
%% current rate of that peer. I wonder if it really belongs in
%% etorrent_peer_states, and not here.
-spec lookup_info(set(), integer(), pid()) -> none | {seeding, float()}
                                                   | {leeching, float()}.
lookup_info(Seeding, Id, Pid) ->
    case sets:is_element(Id, Seeding) of
        true ->
            case etorrent_peer_states:get_send_rate(Id, Pid) of
                none -> none;
                Rate -> {seeding, -Rate} % Negative rate so keysort works
            end;
        false ->
            case etorrent_peer_states:get_recv_rate(Id, Pid) of
                none -> none;
                Rate -> {leeching, -Rate} % Negative rate so keysort works
            end
    end.

build_rechoke_info(Peers) ->
    {value, Seeding} = etorrent_torrent:seeding(),
    SeederSet = sets:from_list(Seeding),
    build_rechoke_info(SeederSet, Peers).

%% Gather information about each Peer so we can choose which peers to
%%  bet on for great download/upload speeds. Produces a #rechoke_info{}
%%  list out of peers containing all information necessary for the choice.
-spec build_rechoke_info(set(), [pid()]) -> [#rechoke_info{}].
build_rechoke_info(_Seeding, []) -> [];
build_rechoke_info(Seeding, [Pid | Next]) ->
    case etorrent_table:get_peer_info(Pid) of
        not_found -> build_rechoke_info(Seeding, Next);
        {peer_info, PeerState, Id} ->
            {value, Snubbed, St} = etorrent_peer_states:get_state(Id, Pid),
            case lookup_info(Seeding, Id, Pid) of
                none -> build_rechoke_info(Seeding, Next);
                {State, R} ->
                    [#rechoke_info {
                        pid = Pid,
                        peer_state = PeerState,
                        state = State,
                        rate = R,
                        r_interest_state =
                            proplists:get_value(interest_state, St),
                        r_choke_state    = proplists:get_value(choke_state, St),
                        l_choke          = proplists:get_value(local_choke, St),
                        peer_snubs = Snubbed } |
                     build_rechoke_info(Seeding, Next)]
            end
    end.

%% Move the chain (that is, circular buffer) so there is a new peer
%% who is the one getting optimistically unchoked.
advance_optimistic_unchoke(S) ->
    NewChain = move_cyclic_chain(S#state.opt_unchoke_chain),
    case NewChain of
        [] ->
            {ok, S}; %% No peers yet
        [H | _T] ->
            etorrent_peer_control:unchoke(H),
            {ok, S#state { opt_unchoke_chain = NewChain,
                           optimistic_unchoke_pid = H }}
    end.

move_cyclic_chain([]) -> [];
move_cyclic_chain(Chain) ->
    F = fun (Pid) ->
                case etorrent_table:get_peer_info(Pid) of
                    not_found -> true;
                    {peer_info, _Kind, Id} ->
                        PL = etorrent_peer_states:get_pids_interest(Id, Pid),
                        %% Peers not interested in us are skipped.
                        %% Optimistically unchoking these would not
                        %% help as they would request nothing. Peers
                        %% already not choking us are in the valuation
                        %% game, so they are also skipped.
                        ( proplists:get_value(interested, PL) == not_interested
                          orelse proplists:get_value(choking, PL) == unchoked )
                end
        end,
    {Front, Back} = lists:splitwith(F, Chain),
    %% Advance chain, happens rarely
    Back ++ Front.

insert_new_peer_into_chain(Pid, []) ->
    [Pid];
insert_new_peer_into_chain(Pid, [_|_] = Chain) ->
    Index = crypto:rand_uniform(0, length(Chain) + 1),
    {Front, Back} = lists:split(Index, Chain),
    Front ++ [Pid | Back].

split_preferred(Peers) ->
    {Downs, Leechs} = split_preferred_peers(Peers, [], []),
    %% Notice that the rate on which we sort is negative,
    %% so the fastest peer is actually first in the list
    {lists:keysort(#rechoke_info.rate, Downs),
     lists:keysort(#rechoke_info.rate, Leechs)}.

%% Given S slots for seeding and D slots for leeching, figure out how many
%% D slots we will need to fill all downloaders. If we need all of them --
%% there are more eligible downloaders then we have slots, leave the slots
%% unchanged. Otherwise, shuffle some of the D slots onto the S slots.
shuffle_leecher_slots(S, D, Len) ->
    case max(0, D - Len) of
        0 -> {S, D};
        N -> {S + N, D - N}
    end.

%% Given S slots for seeding and D slots for leeching, where we have already
%% used shuffle_leecher_slots/3 to move excess slots from D to S, we figure out
%% how many slots we need for S. If we need all of them, we simply return.
%% Otherwise, We have K excess slots we can move from S to D.
shuffle_seeder_slots(S, D, SLen) ->
    case max(0, S - SLen) of
        0 -> {S, D};
        K -> {S - K, D + K}
    end.

%% Figure out how many seeder and leecher slots we need. If there is a surplus
%% for Leechers, say, we push those onto the seeder group and vice versa.
%% This ensures we use all the slots we can possibly use. We return a set
%% of the peers we prefer.
find_preferred_peers(_SDowns, _SLeechs, 0) ->
    lager:warning("MaxUploadSlots = 0."),
    sets:new();
find_preferred_peers(SDowns, SLeechs, MaxUploadSlots) ->
    %% This is not accurate.
    DSlots = max(1, round(MaxUploadSlots * 0.7)),
    SSlots = max(1, round(MaxUploadSlots * 0.3)),
    {SSlots2, DSlots2} = shuffle_leecher_slots(SSlots, DSlots, length(SDowns)),
    {SSlots3, DSlots3} =
        shuffle_seeder_slots(SSlots2, DSlots2, length(SLeechs)),
    {TSDowns, TSLeechs} = {lists:sublist(SDowns, DSlots3),
                           lists:sublist(SLeechs, SSlots3)},
    sets:union(sets:from_list(TSDowns), sets:from_list(TSLeechs)).

rechoke_unchoke([], _PS) -> [];
rechoke_unchoke([P | Next], PSet) ->
    case sets:is_element(P, PSet) of
        true ->
            etorrent_peer_control:unchoke(P#rechoke_info.pid),
            rechoke_unchoke(Next, PSet);
        false ->
            [P | rechoke_unchoke(Next, PSet)]
    end.

rechoke_choke([], _Count, _Optimistics) ->
    ok;
rechoke_choke([P | Next], Count, Optimistics) when Count >= Optimistics ->
    etorrent_peer_control:choke(P#rechoke_info.pid),
    rechoke_choke(Next, Count, Optimistics);
rechoke_choke([P | Next], Count, Optimistics) ->
    case P#rechoke_info.peer_state =:= seeding of
        true ->
            etorrent_peer_control:choke(P#rechoke_info.pid),
            rechoke_choke(Next, Count, Optimistics);
        false ->
            etorrent_peer_control:unchoke(P#rechoke_info.pid),
            case P#rechoke_info.r_interest_state of
                interested ->
                    rechoke_choke(Next, Count+1, Optimistics);
                not_interested ->
                    rechoke_choke(Next, Count, Optimistics)
            end
    end.

%% Split the peers we are connected to into two groups:
%%  - Those we are Leeching from
%%  - Those we are Seeding to
%% But in the process, skip over any peer which is unintersting
split_preferred_peers([], L, S) -> {L, S};
split_preferred_peers(
  [#rechoke_info { peer_state = PeerState, r_interest_state = RemoteInterest,
                   state = State, peer_snubs = Snubbed } = P | Next],
  WeLeech, WeSeed) ->
    case PeerState == seeding orelse RemoteInterest == not_interested of
        true ->
            %% Peer is seeding a torrent or we are connected to a
            %% peer not interested in downloading anything. Unchoking
            %% him would not help anything, skip.
            %% NOTE: In the case he is not_interested, we will unchoke
            %% him anyway at a later phase because we can then start
            %% serving him as soon as possible if his state changes!
            split_preferred_peers(Next, WeLeech, WeSeed);
        false when State =:= seeding ->
            %% We are seeding this torrent, so throw the Peer into the
            %% group of peers we seed to.
            split_preferred_peers(Next, WeLeech, [P | WeSeed]);
        false when Snubbed =:= true ->
            %% The peer has not sent us anything for 30 seconds, so we
            %% regard the peer as snubbing us. Thus, unchoking the peer would
            %% be rather insane. We'd rather use the slot for someone else.
            split_preferred_peers(Next, WeLeech, WeSeed);
        false ->
            %% If none of the other cases match, we have a Peer we are leeching
            %% from, so throw the peer into the leecher set.
            split_preferred_peers(Next, [P | WeLeech], WeSeed)
    end.

%%====================================================================

%% @private
init([]) ->
    MaxUploadSlots = calc_max_upload_slots(),
    MinUploadSlots = etorrent_config:optimistic_slots(),
    S = #state{ min_upload_slots=MinUploadSlots, max_upload_slots=MaxUploadSlots },
    {ok, start_round_timer(S)}.

%% @private
handle_call({monitor, Pid}, _From, S) ->
    _Tref = erlang:monitor(process, Pid),
    NewChain = insert_new_peer_into_chain(Pid, S#state.opt_unchoke_chain),
    perform_rechoke(),
    {reply, ok, S#state { opt_unchoke_chain = NewChain }};
handle_call({set_upload_slots, MinUploadSlots, MaxUploadSlots}, _From, S) ->
    {reply, ok, S#state{ min_upload_slots=MinUploadSlots,
                         max_upload_slots=MaxUploadSlots }};
handle_call({set_round_time, RoundTime}, _From, S) ->
    {reply, ok, start_round_timer(cancel_round_timer(S#state{ round_time=RoundTime}))};

handle_call(Request, _From, State) ->
    lager:error([unknown_peer_group_call, Request]),
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(rechoke, #state { opt_unchoke_chain = Chain } = S) ->
    rechoke(Chain, S),
    {noreply, S}.

%% @private
handle_info(round_tick, S) ->
    lager:info("Round tick."),
    R = case S#state.round of
        0 ->
            {ok, NS} = advance_optimistic_unchoke(S),
            rechoke(NS#state.opt_unchoke_chain, S),
            2;
        N when is_integer(N) ->
            rechoke(S#state.opt_unchoke_chain, S),
            S#state.round - 1
    end,
    {noreply, start_round_timer(S#state{round=R})};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    NewChain = lists:delete(Pid, S#state.opt_unchoke_chain),
    %% Rechoke the chain if the peer was among the unchoked
    rechoke(NewChain, S),
    {noreply, S#state { opt_unchoke_chain = NewChain }}.

%% @private
terminate(_Reason, _S) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================

start_round_timer(S=#state{round_time=Time}) ->
    S#state{round_tref = erlang:send_after(Time, self(), round_tick)}.

cancel_round_timer(S=#state{round_tref=TimerRef}) ->
    erlang:cancel_timer(TimerRef),
    S#state{round_tref=undefined}.
