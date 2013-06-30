%% @author Jesper Louis Andersen <jesper.louis.andersen@gmail.com>
%% @doc Handle a listener pool for incoming connections
%% @end
-module(etorrent_listen_sup).

-behaviour(supervisor).

-export([start_link/1, start_child/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-define(DEFAULT_SOCKET_INCREASE, 10).

%%====================================================================

%% @doc Start up the listener system
%% @end
start_link(PeerId) ->
    {ok, SPid} = supervisor:start_link({local, ?SERVER}, ?MODULE, [PeerId]),
    {ok, _Pid} = start_child(),
    {ok, SPid}.

start_child() ->
    supervisor:start_child(?MODULE, []).
%%====================================================================

init([PeerId]) when is_binary(PeerId) ->
    Port = etorrent_config:listen_port(),
    Ip   = etorrent_config:listen_ip(),
    lager:info("Listening on ~p:~p for BT-connections.", [Ip, Port]),
    ListenOpts = [binary, inet, {active, false}, {reuseaddr, true}]
                 ++ case Ip of all -> []; _ -> [{ip, Ip}] end,
    case gen_tcp:listen(Port, ListenOpts) of
	{ok, LSock} ->
	    AcceptChild =
		{accept_child, {etorrent_acceptor, start_link,
				[PeerId, LSock]},
		 temporary, brutal_kill, worker, [etorrent_acceptor]},
	    RestartStrategy = {simple_one_for_one, 100, 3600},
	    {ok, {RestartStrategy, [AcceptChild]}};
	{error, Reason} ->
	    lager:error("ERROR in gen_tcp:listen/2: ~p~n", [Reason]),
	    exit(gen_tcp_listen)
    end.


%%====================================================================










