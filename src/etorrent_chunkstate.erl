-module(etorrent_chunkstate).
%% This module implements the client interface to processes
%% assigning and tracking the state of chunk requests.
%%
%% This interface is implemented by etorrent_progress, etorrent_pending
%% and etorrent_endgame. Each process type handles a subset of these
%% operations. This module is intended to be used internally by the
%% torrent local services. A wrapper is provided by the etorrent_download
%% module.

%% protocol functions
-export([request/3,
         requests/1,
         assigned/5,
         assigned/3,
         dropped/5,
         dropped/3,
         dropped/2,
         fetched/5,
         stored/5,
         contents/5,
         forward/1]).

%% inspection functions
-export([format_by_peer/1,
         format_by_chunk/1]).


%% @doc Request chunks to download.
%% @end
request(Numchunks, Peerset, Srvpid) ->
    Call = {chunk, {request, Numchunks, Peerset, self()}},
    gen_server:call(Srvpid, Call).

%% @doc Return a list of requests held by a process.
%% @end
-spec requests(pid()) -> [{pid, {integer(), integer(), integer()}}].
requests(SrvPid) ->
    gen_server:call(SrvPid, {chunk, requests}).


%% @doc
%% @end
-spec assigned(non_neg_integer(), non_neg_integer(),
               non_neg_integer(), pid(), pid()) -> ok.
assigned(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {assigned, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec assigned([{non_neg_integer(), non_neg_integer(),
                 non_neg_integer()}], pid(), pid()) -> ok.
assigned(Chunks, Peerpid, Srvpid) ->
    [assigned(P, O, L, Peerpid, Srvpid) || {P, O, L} <- Chunks],
    ok.


%% @doc
%% @end
-spec dropped(non_neg_integer(), non_neg_integer(),
              non_neg_integer(), pid(), pid()) -> ok.
dropped(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {dropped, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec dropped([{non_neg_integer(), non_neg_integer(),
                non_neg_integer()}], pid(), pid()) -> ok.
dropped(Chunks, Peerpid, Srvpid) ->
    [dropped(P, O, L, Peerpid, Srvpid) || {P, O, L} <- Chunks],
    ok.


%% @doc
%% @end
-spec dropped(pid(), pid()) -> ok.
dropped(Peerpid, Srvpid) ->
    Srvpid ! {chunk, {dropped, Peerpid}},
    ok.



%% @doc The chunk was recieved, but it is not written yet (not stored).
%% It is used in the endgame mode.
%% @end
-spec fetched(non_neg_integer(), non_neg_integer(),
                   non_neg_integer(), pid(), pid()) -> ok.
fetched(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {fetched, Piece, Offset, Length, Peerpid}},
    ok.


%% @doc
%% @end
-spec stored(non_neg_integer(), non_neg_integer(),
             non_neg_integer(), pid(), pid()) -> ok.
stored(Piece, Offset, Length, Peerpid, Srvpid) ->
    Srvpid ! {chunk, {stored, Piece, Offset, Length, Peerpid}},
    ok.

%% @doc Send the contents of a chunk to a process.
%% @end
-spec contents(non_neg_integer(), non_neg_integer(),
               non_neg_integer(), binary(), pid()) -> ok.
contents(Piece, Offset, Length, Data, PeerPid) ->
    PeerPid ! {chunk, {contents, Piece, Offset, Length, Data}},
    ok.


%% @doc
%% @end
-spec forward(pid()) -> ok.
forward(Pid) ->
    Tailref = self() ! make_ref(),
    forward_(Pid, Tailref).

forward_(Pid, Tailref) ->
    receive
        Tailref -> ok;
        {chunk, _}=Msg ->
            Pid ! Msg,
            forward_(Pid, Tailref)
    end.


%% @doc
%% @end
-spec format_by_peer(pid()) -> ok.
format_by_peer(SrvPid) ->
    ByPeer = fun({_Pid, _Chunk}=E) -> E end,
    Groups = etorrent_utils:group(ByPeer, requests(SrvPid)),
    io:format("~w~n", [Groups]).


%% @doc
%% @end
-spec format_by_chunk(pid()) -> ok.
format_by_chunk(SrvPid) ->
    ByChunk = fun({Pid, Chunk}) -> {Chunk, Pid} end,
    Groups = etorrent_utils:group(ByChunk, requests(SrvPid)),
    io:format("~w~n", [Groups]).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(chunkstate, ?MODULE).

flush() ->
    {messages, Msgs} = erlang:process_info(self(), messages),
    [receive Msg -> Msg end || Msg <- Msgs].

pop() -> etorrent_utils:first().
make_pid() -> spawn(fun erlang:now/0).

chunkstate_test_() ->
    {foreach,local,
        fun() -> flush() end,
        fun(_) -> flush() end,
        [?_test(test_request()),
         ?_test(test_requests()),
         ?_test(test_assigned()),
         ?_test(test_assigned_list()),
         ?_test(test_dropped()),
         ?_test(test_dropped_list()),
         ?_test(test_dropped_all()),
         ?_test(test_fetched()),
         ?_test(test_stored()),
         ?_test(test_forward()),
         ?_test(test_contents())]}.

test_request() ->
    Peer = self(),
    Set  = make_ref(),
    Num  = make_ref(),
    Srv = spawn_link(fun() ->
        etorrent_utils:reply(fun({chunk, {request, Num, Set, Peer}}) -> ok end)
    end),
    ?assertEqual(ok, ?chunkstate:request(Num, Set, Srv)).

test_requests() ->
    Ref = make_ref(),
    Srv = spawn_link(fun() ->
        etorrent_utils:reply(fun({chunk, requests}) -> Ref end)
    end),
    ?assertEqual(Ref, ?chunkstate:requests(Srv)).

test_assigned() ->
    Pid = make_pid(),
    ok = ?chunkstate:assigned(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {assigned, 1, 2, 3, Pid}}, pop()).

test_assigned_list() ->
    Pid = make_pid(),
    Chunks = [{1, 2, 3}, {4, 5, 6}],
    ok = ?chunkstate:assigned(Chunks, Pid, self()),
    ?assertEqual({chunk, {assigned, 1, 2, 3, Pid}}, pop()),
    ?assertEqual({chunk, {assigned, 4, 5, 6, Pid}}, pop()).

test_dropped() ->
    Pid = make_pid(),
    ok = ?chunkstate:dropped(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {dropped, 1, 2, 3, Pid}}, pop()).

test_dropped_list() ->
    Pid = make_pid(),
    Chunks = [{1, 2, 3}, {4, 5, 6}],
    ok = ?chunkstate:dropped(Chunks, Pid, self()),
    ?assertEqual({chunk, {dropped, 1, 2, 3, Pid}}, pop()),
    ?assertEqual({chunk, {dropped, 4, 5, 6, Pid}}, pop()).

test_dropped_all() ->
    Pid = make_pid(),
    ok = ?chunkstate:dropped(Pid, self()),
    ?assertEqual({chunk, {dropped, Pid}}, pop()).

test_fetched() ->
    Pid = make_pid(),
    ok = ?chunkstate:fetched(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {fetched, 1, 2, 3, Pid}}, pop()).

test_stored() ->
    Pid = make_pid(),
    ok = ?chunkstate:stored(1, 2, 3, Pid, self()),
    ?assertEqual({chunk, {stored, 1, 2, 3, Pid}}, pop()).

test_contents() ->
    ok = ?chunkstate:contents(1, 2, 3, <<1,2,3>>, self()),
    ?assertEqual({chunk, {contents, 1, 2, 3, <<1,2,3>>}}, pop()).

test_forward() ->
    Main = self(),
    Pid = make_pid(),
    {Slave, Ref} = erlang:spawn_monitor(fun() ->
        etorrent_utils:expect(go),
        ?chunkstate:forward(Main),
        etorrent_utils:expect(die)
    end),
    ok = ?chunkstate:assigned(1, 2, 3, Pid, Slave),
    ok = ?chunkstate:assigned(4, 5, 6, Pid, Slave),
    Slave ! go,
    ?assertEqual({chunk, {assigned, 1, 2, 3, Pid}}, pop()),
    ?assertEqual({chunk, {assigned, 4, 5, 6, Pid}}, pop()),
    Slave ! die,
    etorrent_utils:wait(Ref).

-endif.
