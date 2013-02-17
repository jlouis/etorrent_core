-module(etorrent_dotdir).
%% @doc Functions to access the .etorrent directory.
%% @end

%% exported functions
-export([make/0,
         torrents/0,
         copy_torrent/1,
         read_torrent/1,
         torrent_path/1,
         info_path/1,
         info_hash/1,
         read_info/1,
         write_info/2]).

%% private functions
-export([exists/1]).

%% include files
-include_lib("kernel/include/file.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% @doc Ensure that the dotfile directory exists.
%% @end
-spec make() -> ok.
make() ->
    Dir = etorrent_config:dotdir(),
    case exists(Dir) of
        true -> ok;
        false -> file:make_dir(Dir)
    end.

%% @doc List all available torrent files.
%% The torrent files are identified by their info hashes. This is more
%% correct than trusting that all torrent files has been assigned a unique
%% filename.
%% @end
-spec torrents() -> {ok, [Filenames::string()]} | {error, noent}.
torrents() ->
    case file:list_dir(etorrent_config:dotdir()) of
        {ok, Files} ->
            IsTorrent = fun(Str) -> lists:suffix(".torrent", Str) end,
            Basename = fun(Str) -> filename:basename(Str, ".torrent") end,
            Torrents = [Basename(I) || I <- Files, IsTorrent(I)],
            %% @todo filter out files whose basename does not appear to
            %% to be a valid hex encoded info hash?
            {ok, Torrents};
        {error, _}=Error ->
            Error
    end.

%% @doc Make a private copy of a torrent file.
%% The info hash of the torrent is returned. After a torrent has been copied
%% the info hash should be used to identify a torrent path.
%% @end
-spec copy_torrent(Torrentfile::string()) -> {ok, Infohash::[byte()]}.
copy_torrent(Torrentfile) when is_list(Torrentfile) ->
    case info_hash(Torrentfile) of
        {error, _}=Error ->
            Error;
        {ok, Infohash} ->
            Dest = torrent_path(Infohash),
            case file:copy(Torrentfile, Dest) of
                {error, _}=Error -> Error;
                {ok, _} -> {ok, Infohash}
            end
    end.


%% @doc Return the contents of a torrent.
%% @end
-spec read_torrent(Infohash::[byte()]) ->
                          {ok, etorrent_types:bcode()} | {error, _}.
read_torrent(Infohash) ->
    Path = torrent_path(Infohash),
    case file:read_file(Path) of
        {error, _}=Error ->
            Error;
        {ok, Bin} ->
            etorrent_bcoding:decode(Bin)
    end.


%% @doc Return the private path to a copied torrent metadata file.
%% @end
-spec torrent_path(Infohash::[byte()]) -> Torrentpath::string().
torrent_path(Infohash) ->
    base_path(Infohash) ++ ".torrent".


%% @doc Return the private path to a a torrent info file.
%% @end
-spec info_path(Infohash::[byte()]) -> Infopath::string().
info_path(Infohash) ->
    base_path(Infohash) ++ ".info".


%% @doc Return a path pointing into the private directory.
%% A path based on the info hash should be more unique than a path based
%% on the original torrent filename or filenames within a torrent.
%% @end
-spec base_path(Infohash::[byte()]) -> Path::string().
base_path(Infohash) ->
    assert_hex_hash(Infohash),
    filename:join([etorrent_config:dotdir(), Infohash]).


%% @doc Get the literal info hash of a torrent file.
%% @end
-spec info_hash(Torrentfile::string()) -> {ok, [byte()]} | {error, _}.
info_hash(Torrentfile) ->
    case file:read_file(Torrentfile) of
        {ok, Bin} ->
            {ok, Terms} = etorrent_bcoding:decode(Bin),
            Infohash = etorrent_metainfo:get_infohash(Terms),
            {ok, info_hash_to_hex(Infohash)};
        {error, _}=Error ->
            Error
    end.

%% @private Hex encode an info hash.
info_hash_to_hex(<<Infohash:160>>) ->
    binary_to_list(iolist_to_binary(io_lib:format("~40.16.0b", [Infohash]))).


%% @private Catch raw info hashes that slips through.
assert_hex_hash(Infohash) ->
    length(Infohash) =:= 40 orelse erlang:error(badlength),
    IsHex = fun
        (C) when C >= $0, C =< $9 -> true;
        (C) when C >= $a, C =< $f -> true;
        (_) -> false
    end,
    lists:all(IsHex, Infohash) orelse erlang:error(badhex).
    

%% @doc Read the contents of the .info file of a torrent.
%% @end
-spec read_info(Infohash :: [byte()]) ->
                       {ok, etorrent_types:bcode()} | {error, atom()}.
read_info(Infohash) ->
    Path = info_path(Infohash),
    case file:read_file(Path) of
        {error, _}=Error ->
            Error;
        {ok, Bin} ->
            etorrent_bcoding:decode(Bin)
    end.

%% @doc Rewrite the contents of the .info file of a torrent.
%% @end
-spec write_info(Infohash :: [byte()], etorrent_types:bcode()) ->
                        ok | {error, atom()}.
write_info(Infohash, Data) ->
    Bin = etorrent_bcoding:encode(Data),
    File = info_path(Infohash),
    file:write_file(File, Bin).

    

%% @private Check if a file path exists.
%% XXX: Make separate assertion on the filetype.
-spec exists(Path::string()) -> boolean().
exists(Path) ->
    case file:read_file_info(Path) of
        {ok, _} -> true;
        {error, _} -> false
    end.


-ifdef(TEST).

infohash_test_() ->
    FileName =
    filename:join(code:lib_dir(etorrent_core),
                  "test/etorrent_eunit_SUITE_data/test_file_30M.random.torrent"),
    [?_assertEqual({ok, "87be033150bd8dd1801478a32d4c79e54cb55552"}, 
                   ?MODULE:info_hash(FileName))].


%% @private Update dotdir configuration parameter to point to a new directory.
setup_config() ->
    Dir = test_server:temp_name("/tmp/etorrent."),
    ok = meck:new(etorrent_config, []),
    ok = meck:expect(etorrent_config, dotdir, fun () -> Dir end).

%% @private Delete the directory pointed to by the dotdir configuration parameter.
teardown_config(_) ->
    %% @todo Recursive file:delete.
    ok = meck:unload(etorrent_config).

testpath() ->
    "../" "../" "../"
    "test/" "etorrent_eunit_SUITE_data/debian-6.0.2.1-amd64-netinst.iso.torrent".

testhex()  -> "8ed7dab51f46d8ecc2d08dcc1c1ca088ed8a53b4".
testinfo() -> "8ed7dab51f46d8ecc2d08dcc1c1ca088ed8a53b4.info".


dotfiles_test_() ->
    {setup,local,
        fun() -> application:start(gproc) end,
        fun(_) -> application:stop(gproc) end, [
        {foreach,local, 
            fun setup_config/0,
            fun teardown_config/1, [
            ?_test(test_no_torrents()),
            ?_test(test_ensure_exists()),
            test_ensure_exists_error_()] ++
            [{setup,local,
                fun() -> ?MODULE:make() end,
                fun(_) -> ok end,
                [T]} || T <- [
                ?_test(test_copy_torrent()),
                test_copy_torrent_error_(),
                ?_test(test_info_filename()),
                ?_test(test_info_hash()),
                ?_test(test_read_torrent()),
                ?_test(test_read_info()),
                ?_test(test_write_info())]]
        }
    ]}.

test_no_torrents() ->
    ?assertEqual({error, enoent}, ?MODULE:torrents()).

test_ensure_exists() ->
    ?assertNot(?MODULE:exists(etorrent_config:dotdir())),
    ok = ?MODULE:make(),
    ?assert(?MODULE:exists(etorrent_config:dotdir())).

test_ensure_exists_error_() ->
    {setup,
        _Setup=fun() ->
        ok = meck:new(file, [unstick,passthrough]),
        ok = meck:expect(file, read_file_info, fun(_) -> {error, enoent} end),
        ok = meck:expect(file, make_dir, fun(_) -> {error, eacces} end)
        end,
        _Teardown=fun(_) -> 
        meck:unload(file)
        end,
        {inorder, [
            ?_assertEqual({error, eacces}, ?MODULE:make()),
            ?_assert(meck:validate(file))]}}.

test_copy_torrent() ->
    ?assertEqual({ok, testhex()}, ?MODULE:copy_torrent(testpath())),
    ?assertEqual({ok, [testhex()]}, ?MODULE:torrents()).

test_copy_torrent_error_() ->
     {setup,
        _Setup=fun() ->
        ok = meck:new(file, [unstick,passthrough]),
        ok = meck:expect(file, copy, fun(_, _) -> {error, eacces} end)
        end,
        _Teardown=fun(_) -> 
        meck:unload(file)
        end,
        {inorder, [
            ?_assertEqual({error, eacces}, ?MODULE:copy_torrent(testpath())),
            ?_assertEqual({ok, []}, ?MODULE:torrents()),
            ?_assert(meck:validate(file))]}}.
   

test_info_filename() ->
    {ok, Infohash} = ?MODULE:copy_torrent(testpath()),
    ?assertEqual(testinfo(), lists:last(filename:split(?MODULE:info_path(Infohash)))).

test_info_hash() ->
    ?assertEqual({ok, testhex()}, ?MODULE:info_hash(testpath())).

test_read_torrent() ->
    {ok, Infohash} = ?MODULE:copy_torrent(testpath()),
    {ok, Metadata} = ?MODULE:read_torrent(Infohash),
    RawInfohash = etorrent_metainfo:get_infohash(Metadata),
    ?assertEqual(Infohash, info_hash_to_hex(RawInfohash)).

test_read_info() ->
    {ok, Infohash} = ?MODULE:copy_torrent(testpath()),
    {error, enoent} = ?MODULE:read_info(Infohash).

test_write_info() ->
    {ok, Infohash} = ?MODULE:copy_torrent(testpath()),
    ok = ?MODULE:write_info(Infohash, [{<<"a">>, 1}]),
    {ok, [{<<"a">>, 1}]} = ?MODULE:read_info(Infohash).


-endif.
