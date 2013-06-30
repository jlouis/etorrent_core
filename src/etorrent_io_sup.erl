%% @author Magnus Klaar <magnus.klaar@sgsstudentbostader.se>
%% @doc Supervise a set of file system processes
%% <p>This supervisor is responsible for overseeing the file system
%% processes for a single torrent.</p>
%% @end
-module(etorrent_io_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

-type bcode() :: etorrent_types:bcode().
-type torrent_id() :: etorrent_types:torrent_id().


%% @doc Initiate the supervisor.
%% <p>The arguments are the ID of the torrent and the
%% parsed torrent file</p>
%% @end
-spec start_link(torrent_id(), bcode()) -> {'ok', pid()}.
start_link(TorrentID, Torrent) ->
    supervisor:start_link(?MODULE, [TorrentID, Torrent]).

%% ----------------------------------------------------------------------

%% @private
init([TorrentID, Torrent]) ->
    lager:debug("Init IO supervisor for ~p.", [TorrentID]),
    Files     = etorrent_metainfo:file_paths(Torrent),
    DirServer = directory_server_spec(TorrentID, Torrent),
    ok        = etorrent_torrent:await_entry(TorrentID),
    Dldir     = etorrent_torrent:get_download_dir(TorrentID),
    FileSup   = file_server_sup_spec(TorrentID, Dldir, Files),
    lager:debug("Completing initialization of IO supervisor for ~p.", [TorrentID]),
    erlang:garbage_collect(),
    {ok, {{one_for_one, 1, 60}, [FileSup, DirServer]}}.

%% ----------------------------------------------------------------------
directory_server_spec(TorrentID, Torrent) ->
    {{TorrentID, directory},
        {etorrent_io, start_link, [TorrentID, Torrent]},
        permanent, 2000, worker, [etorrent_io]}.

file_server_sup_spec(TorrentID, Workdir, Files) ->
    Args = [TorrentID, Workdir, Files],
    {{TorrentID, file_server_sup},
        {etorrent_io_file_sup, start_link, Args},
        permanent, 2000, supervisor, [etorrent_file_io_sup]}.
