-module(uds_dist).
-moduledoc """
Erlang distribution over Unix domain sockets via the `socket` module.

See the [README](readme.html) for configuration, release integration,
platform support, and local development notes.

This module implements the callbacks OTP requires of a custom
distribution protocol (`listen/1`, `accept/1`, `accept_connection/5`,
`setup/5`, `close/1`, `select/1`, `address/0`, plus the optional
`setopts/2`, `getopts/2`). It is loaded by passing `-proto_dist uds` to
the BEAM at boot; the callbacks are invoked by the kernel's
distribution machinery, not by user code, and are not documented here.

The implementation is modelled on the `erl_uds_dist` example in
`lib/kernel/examples` with several simplifications: the `socket` NIF
rather than `gen_tcp`, distribution protocol version 6 only, abstract
namespace support on Linux, and socket-path resolution driven by
application configuration (the `:socket_dir` value on the `:uds_dist`
application environment), the `UDS_DIST_DIR` environment variable, or a
host-global path derived from the node name under `/tmp`.

The listen backlog and trusted-peer UID policy are read from the application
environment at `listen/1` time. The backlog defaults to 5, while
`:allowed_uids` defaults to the process's effective UID and also accepts
`:any` or a list of numeric UIDs. Outbound-only nodes read the same policy
when they connect.
""".

-export([listen/1, accept/1, accept_connection/5,
         setup/5, close/1, select/1, address/0]).
-export([setopts/2, getopts/2]).
-export([accept_loop/3, accept_handshake/2,
         accept_supervisor/6, setup_supervisor/5]).

%% Exported for testing.
-export([resolve_path/1, configured_allowed_uids/0,
         strip_host/1, abstract_supported/0]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").
-include_lib("kernel/include/file.hrl").

-define(ERL_DIST_VER, 6).
-define(SPAWN_OPTS, [{message_queue_data, off_heap}, {fullsweep_after, 0}]).
-define(DEFAULT_BACKLOG, 5).
-define(LINUX_SUN_PATH_BYTES, 108).
-define(BSD_SUN_PATH_BYTES, 104).
-define(REJECTION_LOG_INTERVAL_MS, 5000).
-define(SOCKET_DIR_KEY, {?MODULE, socket_dir}).
-define(ALLOWED_UIDS_KEY, {?MODULE, allowed_uids}).

%%% =====================================================================
%%% Distribution callbacks
%%% =====================================================================

-doc false.
select(_NodeName) ->
    true.

-doc false.
address() ->
    net_address(undefined).

-doc false.
listen(NameAtom) ->
    case peer_credentials_supported() of
        true ->
            case uds_dist_posix:ensure_loaded() of
                ok -> do_listen(NameAtom);
                {error, _} = Error -> Error
            end;
        false ->
            {error, {peer_credentials_unsupported, os:type()}}
    end.

do_listen(NameAtom) ->
    Dir = configured_socket_dir(),
    AllowedUIDs = configured_allowed_uids(),
    Path = resolve_path(atom_to_list(NameAtom), Dir),
    case ensure_socket_dir(Dir) of
        ok ->
            case open_and_bind(Path) of
                {ok, Listen} ->
                    persistent_term:put(?SOCKET_DIR_KEY, Dir),
                    persistent_term:put(?ALLOWED_UIDS_KEY, AllowedUIDs),
                    logger:notice(
                      "uds_dist listening on ~tp with allowed_uids=~tp",
                      [Path, AllowedUIDs]),
                    {ok, {Listen, net_address(sockaddr_to_address(Path)),
                          creation()}};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc false.
accept(ListenSocket) ->
    AllowedUIDs = persistent_term:get(?ALLOWED_UIDS_KEY),
    spawn_opt(?MODULE, accept_loop, [self(), ListenSocket, AllowedUIDs],
              [link, {priority, max} | ?SPAWN_OPTS]).

-doc false.
accept_connection(AcceptPid, DistCtrl, MyNode, Allowed, SetupTime) ->
    spawn_opt(?MODULE, accept_supervisor,
              [self(), AcceptPid, DistCtrl, MyNode, Allowed, SetupTime],
              dist_util:net_ticker_spawn_options()).

-doc false.
setup(Node, Type, MyNode, _LongOrShortNames, SetupTime) ->
    spawn_opt(?MODULE, setup_supervisor,
              [self(), Node, Type, MyNode, SetupTime],
              dist_util:net_ticker_spawn_options()).

-doc false.
close(ListenSocket) ->
    case socket:sockname(ListenSocket) of
        {ok, #{family := local, path := Path}} ->
            maybe_unlink(Path);
        _ ->
            ok
    end,
    Result = socket:close(ListenSocket),
    persistent_term:erase(?SOCKET_DIR_KEY),
    persistent_term:erase(?ALLOWED_UIDS_KEY),
    Result.

-doc false.
setopts(_ListenSocket, _Options) ->
    ok.

-doc false.
getopts(_ListenSocket, _Options) ->
    {ok, []}.

%%% =====================================================================
%%% Path resolution and helpers
%%% =====================================================================

%% Resolve a node-name-without-host to a sockaddr_un path (binary). Reuses
%% the path strategy selected by listen/1 when available, so outbound setup
%% cannot drift if the environment changes after boot. A leading "@" on
%% the configured dir selects the Linux abstract namespace.
-doc false.
resolve_path(Name) when is_list(Name) ->
    Dir = persistent_term:get(?SOCKET_DIR_KEY, undefined),
    resolve_path(Name, case Dir of
                           undefined -> configured_socket_dir();
                           _ -> Dir
                       end).

resolve_path(Name, Dir) ->
    NameBin = unicode:characters_to_binary(Name),
    Path = case Dir of
        default_tmp ->
            <<"/tmp/uds-dist-", NameBin/binary, ".sock">>;
        <<"@", Rest/binary>> ->
            true = abstract_supported() orelse
                erlang:error({abstract_sockets_unsupported, os:type()}),
            %% Abstract paths are signalled by a leading NUL byte and live
            %% in the kernel namespace, not the filesystem.
            <<0, Rest/binary, "/", NameBin/binary>>;
        _ ->
            filename:join(Dir, <<NameBin/binary, ".sock">>)
    end,
    validate_socket_path(Path).

configured_socket_dir() ->
    %% Ensure the .app file is loaded so that -uds_dist socket_dir Path
    %% args (resolved into app env at load time) are visible. Releases
    %% load us via the boot script; ad-hoc invocations may not have.
    ok = ensure_application_loaded(),
    case application:get_env(uds_dist, socket_dir) of
        {ok, AppDir} -> normalize_socket_dir(AppDir);
        undefined -> environment_socket_dir()
    end.

-doc false.
configured_allowed_uids() ->
    ok = ensure_application_loaded(),
    Value = application:get_env(uds_dist, allowed_uids, default),
    normalize_allowed_uids(Value).

ensure_application_loaded() ->
    case application:load(uds_dist) of
        ok -> ok;
        {error, {already_loaded, uds_dist}} -> ok;
        {error, Reason} -> erlang:error({application_load_failed, Reason})
    end.

normalize_socket_dir(Value) ->
    try unicode:characters_to_binary(Value) of
        Dir when is_binary(Dir), byte_size(Dir) > 0 -> Dir;
        _ -> erlang:error({invalid_socket_dir, Value})
    catch
        error:badarg -> erlang:error({invalid_socket_dir, Value})
    end.

normalize_allowed_uids(default) ->
    normalize_uid_list([uds_dist_posix:effective_uid()]);
normalize_allowed_uids(any) ->
    any;
normalize_allowed_uids(UIDs) when is_list(UIDs) ->
    case lists:all(fun(UID) -> is_integer(UID) andalso UID >= 0 end, UIDs) of
        true -> normalize_uid_list(UIDs);
        false -> erlang:error({invalid_allowed_uids, UIDs})
    end;
normalize_allowed_uids(Value) ->
    erlang:error({invalid_allowed_uids, Value}).

normalize_uid_list(UIDs) ->
    Normalized = lists:usort(UIDs),
    case os:type() of
        {unix, linux} -> reject_linux_overflow_uid(Normalized);
        _ -> Normalized
    end.

reject_linux_overflow_uid([]) ->
    [];
reject_linux_overflow_uid(UIDs) ->
    OverflowUID = linux_overflow_uid(),
    case lists:member(OverflowUID, UIDs) of
        true ->
            erlang:error(
              {invalid_allowed_uids,
               {contains_linux_overflow_uid, OverflowUID, UIDs}});
        false ->
            UIDs
    end.

linux_overflow_uid() ->
    Path = "/proc/sys/kernel/overflowuid",
    case file:read_file(Path) of
        {ok, Contents} ->
            try binary_to_integer(string:trim(Contents)) of
                UID when UID >= 0 -> UID;
                _ -> erlang:error({invalid_linux_overflow_uid, Contents})
            catch
                error:badarg ->
                    erlang:error({invalid_linux_overflow_uid, Contents})
            end;
        {error, Reason} ->
            erlang:error({linux_overflow_uid_unavailable, Path, Reason})
    end.

environment_socket_dir() ->
    case nonempty_env("UDS_DIST_DIR") of
        {ok, Dir} -> normalize_socket_dir(Dir);
        unset -> default_tmp
    end.

nonempty_env(Name) ->
    case os:getenv(Name) of
        false -> unset;
        "" -> unset;
        Value -> {ok, Value}
    end.

ensure_socket_dir(<<"@", _/binary>>) ->
    ok;
ensure_socket_dir(default_tmp) ->
    ok;
ensure_socket_dir(Dir) ->
    case file:make_dir(Dir) of
        ok ->
            case file:change_mode(Dir, 8#755) of
                ok -> validate_socket_dir(Dir);
                {error, _} = Error -> Error
            end;
        {error, eexist} ->
            validate_socket_dir(Dir);
        {error, _} = Error ->
            Error
    end.

validate_socket_dir(Dir) ->
    case file:read_link_info(Dir, [raw]) of
        {ok, #file_info{type = symlink}} ->
            unsafe_socket_dir(Dir, symlink);
        {ok, #file_info{type = Type}} when Type =/= directory ->
            unsafe_socket_dir(Dir, not_directory);
        {ok, #file_info{uid = ActualUID, mode = Mode}} ->
            ExpectedUID = uds_dist_posix:effective_uid(),
            validate_socket_dir_owner(Dir, ActualUID, ExpectedUID, Mode);
        {error, _} = Error ->
            Error
    end.

validate_socket_dir_owner(Dir, ActualUID, ExpectedUID, _Mode)
  when ActualUID =/= ExpectedUID ->
    unsafe_socket_dir(Dir, {not_owned, ActualUID, ExpectedUID});
validate_socket_dir_owner(Dir, _ActualUID, _ExpectedUID, Mode) ->
    Permissions = Mode band 8#777,
    case Permissions of
        8#755 -> ok;
        _ -> unsafe_socket_dir(Dir, {unsafe_mode, Permissions})
    end.

unsafe_socket_dir(Dir, Reason) ->
    {error, {unsafe_socket_dir, Dir, Reason}}.

-doc false.
abstract_supported() ->
    case os:type() of
        {unix, linux} -> true;
        _ -> false
    end.

peer_credentials_supported() ->
    case os:type() of
        {unix, OS} when OS =:= linux;
                        OS =:= darwin;
                        OS =:= freebsd;
                        OS =:= netbsd;
                        OS =:= openbsd;
                        OS =:= dragonfly -> true;
        _ -> false
    end.

validate_socket_path(Path) ->
    case socket_path_limit() of
        undefined ->
            Path;
        Limit ->
            %% Filesystem paths need a trailing NUL in sun_path. Linux
            %% abstract names are length-delimited and already include their
            %% leading NUL byte.
            Bytes = case Path of
                        <<0, _/binary>> -> byte_size(Path);
                        _ -> byte_size(Path) + 1
                    end,
            case Bytes =< Limit of
                true -> Path;
                false ->
                    erlang:error({socket_path_too_long, Path, Limit})
            end
    end.

socket_path_limit() ->
    case os:type() of
        {unix, linux} -> ?LINUX_SUN_PATH_BYTES;
        {unix, OS} when OS =:= darwin;
                        OS =:= freebsd;
                        OS =:= netbsd;
                        OS =:= openbsd;
                        OS =:= dragonfly -> ?BSD_SUN_PATH_BYTES;
        _ -> undefined
    end.

-doc false.
strip_host(Node) when is_atom(Node) ->
    strip_host(atom_to_list(Node));
strip_host(Node) when is_list(Node) ->
    lists:takewhile(fun(C) -> C =/= $@ end, Node).

%% Distribution protocol version 6 only requires a unique 32-bit creation.
%% Reserve 0..3 (legacy v5 small-creation range and the 0 wildcard).
creation() ->
    3 + rand:uniform((1 bsl 32) - 4).

open_and_bind(Path) ->
    {ok, S} = socket:open(local, stream, default),
    case socket:bind(S, sockaddr(Path)) of
        ok ->
            case make_socket_connectable(Path) of
                ok ->
                    Backlog = application:get_env(uds_dist, backlog,
                                                  ?DEFAULT_BACKLOG),
                    ok = socket:listen(S, Backlog),
                    {ok, S};
                {error, _} = Error ->
                    socket:close(S),
                    maybe_unlink(Path),
                    Error
            end;
        {error, eaddrinuse} ->
            socket:close(S),
            handle_eaddrinuse(Path);
        {error, _} = Err ->
            socket:close(S),
            Err
    end.

make_socket_connectable(<<0, _/binary>>) ->
    ok;
make_socket_connectable(Path) ->
    %% The configured owner-only directory, or /tmp's sticky bit for the
    %% default, prevents other users from replacing a live socket entry.
    %% Connection authorization uses kernel peer credentials in accept_loop/3.
    file:change_mode(Path, 8#666).

%% Distinguish a live duplicate from a stale socket file. For abstract
%% sockets the kernel cleans up on close so eaddrinuse always means
%% another process is bound — no retry possible.
handle_eaddrinuse(<<0, _/binary>>) ->
    {error, duplicate_name};
handle_eaddrinuse(Path) ->
    case probe(Path) of
        alive ->
            {error, duplicate_name};
        stale ->
            case file:delete(Path, [raw]) of
                ok -> open_and_bind(Path);
                %% Another process may have removed the same stale entry.
                %% Retry the bind and let the next eaddrinuse probe decide
                %% whether a new owner won the race.
                {error, enoent} -> open_and_bind(Path);
                {error, _} = Error -> Error
            end
    end.

probe(Path) ->
    {ok, S} = socket:open(local, stream, default),
    Result = case socket:connect(S, sockaddr(Path)) of
                 ok -> alive;
                 {error, _} -> stale
             end,
    socket:close(S),
    Result.

sockaddr(Path) ->
    #{family => local, path => Path}.

net_address(Addr) ->
    #net_address{address = Addr, host = localhost,
                 family = local, protocol = stream}.

%% Adapt :socket's sockaddr_un to the legacy {local, ...} shape stored in
%% #net_address.address so that consumers reading net_address don't have
%% to know about the new map form.
sockaddr_to_address(<<0, _/binary>> = Abstract) -> {local, Abstract};
sockaddr_to_address(Path) when is_binary(Path) -> {local, binary_to_list(Path)}.

maybe_unlink(<<0, _/binary>>) ->
    ok;
maybe_unlink(Path) ->
    _ = file:delete(Path, [raw]),
    ok.

%%% =====================================================================
%%% Accept side
%%% =====================================================================

-doc false.
accept_loop(Kernel, ListenSocket, AllowedUIDs) ->
    case socket:accept(ListenSocket) of
        {ok, Socket} ->
            case authorize_peer(Socket, AllowedUIDs) of
                {ok, _UID} ->
                    %% Hand the handshake to a per-connection helper so the
                    %% loop can immediately re-enter socket:accept/1. Without
                    %% this the loop is serialised by the kernel handshake
                    %% round-trip and the listen backlog can overflow under
                    %% bursts of concurrent dialers.
                    _ = spawn_opt(?MODULE, accept_handshake, [Kernel, Socket],
                                  [{priority, max} | ?SPAWN_OPTS]);
                {error, {peer_uid_not_allowed, _}} = Error ->
                    maybe_log_rejection(warning,
                                        "uds_dist rejected local peer",
                                        Error),
                    _ = socket:close(Socket);
                {error, Reason} ->
                    maybe_log_rejection(
                      error, "uds_dist could not authorize local peer", Reason),
                    _ = socket:close(Socket)
            end,
            accept_loop(Kernel, ListenSocket, AllowedUIDs);
        {error, closed} ->
            exit(closing_connection);
        Error ->
            exit(Error)
    end.

authorize_peer(Socket, AllowedUIDs) ->
    try uds_dist_posix:peer_effective_uid(Socket) of
        {ok, UID} ->
            case uid_allowed(UID, AllowedUIDs) of
                true -> {ok, UID};
                false -> {error, {peer_uid_not_allowed, UID}}
            end;
        {error, _} = Error ->
            Error
    catch
        Class:Reason ->
            {error, {peer_credential_exception, Class, Reason}}
    end.

uid_allowed(_UID, any) -> true;
uid_allowed(UID, AllowedUIDs) -> lists:member(UID, AllowedUIDs).

maybe_log_rejection(Level, Message, Reason) ->
    Now = erlang:monotonic_time(millisecond),
    Key = {?MODULE, rejection_log, Level},
    case get(Key) of
        undefined ->
            put(Key, {Now, 0}),
            logger:log(Level, "~s: ~tp", [Message, Reason]);
        {LastLog, Suppressed}
          when Now - LastLog >= ?REJECTION_LOG_INTERVAL_MS ->
            put(Key, {Now, 0}),
            log_rejection(Level, Message, Reason, Suppressed);
        {LastLog, Suppressed} ->
            put(Key, {LastLog, Suppressed + 1}),
            ok
    end.

log_rejection(Level, Message, Reason, 0) ->
    logger:log(Level, "~s: ~tp", [Message, Reason]);
log_rejection(Level, Message, Reason, Suppressed) ->
    logger:log(Level, "~s: ~tp (~B similar events suppressed)",
               [Message, Reason, Suppressed]).

-doc false.
accept_handshake(Kernel, Socket) ->
    DistCtrl = spawn_dist_controller(Socket, [link]),
    Kernel ! {accept, self(), DistCtrl, local, stream},
    receive
        {Kernel, controller, SupervisorPid} ->
            call_controller(DistCtrl, {supervisor, SupervisorPid}),
            SupervisorPid ! {self(), controller};
        {Kernel, unsupported_protocol} ->
            %% The accepted socket is owned by the long-lived accept loop,
            %% so explicitly close it as well as terminating the linked
            %% controller.
            _ = socket:close(Socket),
            exit(unsupported_protocol)
    end.

-doc false.
accept_supervisor(Kernel, AcceptPid, DistCtrl, MyNode, Allowed, SetupTime) ->
    receive
        {AcceptPid, controller} ->
            Timer = dist_util:start_timer(SetupTime),
            HSData = (hs_data_common(DistCtrl))#hs_data{
                       kernel_pid = Kernel,
                       this_node = MyNode,
                       socket = DistCtrl,
                       timer = Timer,
                       allowed = Allowed,
                       %% Accepted peer is unnamed at the sockaddr level
                       %% (only the listening side has a bound path), so
                       %% report an empty address — same convention as
                       %% erl_uds_dist.
                       f_address = fun(_, _) -> net_address([]) end
                      },
            dist_util:handshake_other_started(HSData)
    end.

%%% =====================================================================
%%% Setup (outbound) side
%%% =====================================================================

-doc false.
setup_supervisor(Kernel, Node, Type, MyNode, SetupTime) ->
    Name = strip_host(Node),
    Path = resolve_path(Name),
    AllowedUIDs = selected_allowed_uids(),
    {ok, Socket} = socket:open(local, stream, default),
    case socket:connect(Socket, sockaddr(Path)) of
        ok ->
            case authorize_peer(Socket, AllowedUIDs) of
                {ok, _UID} ->
                    start_outbound_handshake(
                      Kernel, Socket, Node, Type, MyNode, SetupTime, Path);
                {error, Reason} ->
                    socket:close(Socket),
                    logger:warning(
                      "uds_dist rejected server at ~tp: ~tp", [Path, Reason]),
                    ?shutdown(Node)
            end;
        {error, Reason} ->
            socket:close(Socket),
            logger:warning("uds_dist could not connect to ~tp: ~tp",
                           [Path, Reason]),
            ?shutdown(Node)
    end.

selected_allowed_uids() ->
    case persistent_term:get(?ALLOWED_UIDS_KEY, undefined) of
        undefined -> configured_allowed_uids();
        AllowedUIDs -> AllowedUIDs
    end.

start_outbound_handshake(Kernel, Socket, Node, Type, MyNode, SetupTime, Path) ->
    Timer = dist_util:start_timer(SetupTime),
    DistCtrl = spawn_dist_controller(Socket),
    call_controller(DistCtrl, {supervisor, self()}),
    HSData = (hs_data_common(DistCtrl))#hs_data{
               kernel_pid = Kernel,
               other_node = Node,
               this_node = MyNode,
               socket = DistCtrl,
               timer = Timer,
               other_version = ?ERL_DIST_VER,
               request_type = Type,
               f_address = fun(_, _) ->
                                   net_address(sockaddr_to_address(Path))
                           end
              },
    dist_util:handshake_we_started(HSData).

%%% =====================================================================
%%% Handshake data record shared by accept and setup
%%% =====================================================================

hs_data_common(DistCtrl) ->
    #hs_data{
       this_flags = 0,
       f_send = fun(Ctrl, Packet) ->
                        call_controller(Ctrl, {send, Packet})
                end,
       f_recv = fun(Ctrl, Length, Timeout) ->
                        case call_controller(Ctrl, {recv, Length, Timeout}) of
                            {ok, Bin} when is_binary(Bin) ->
                                {ok, binary_to_list(Bin)};
                            Other ->
                                Other
                        end
                end,
       %% pre/post nodeup are no-ops: framing length is implicit per-process
       %% (setup loop uses 2-byte, output/input handlers use 4-byte) so there
       %% is nothing to flip when transitioning between handshake and data.
       f_setopts_pre_nodeup = fun(_) -> ok end,
       f_setopts_post_nodeup = fun(_) -> ok end,
       f_getll = fun(Ctrl) -> {ok, Ctrl} end,
       mf_tick = fun(Ctrl) when Ctrl =:= DistCtrl ->
                         DistCtrl ! send_tick,
                         ok
                 end,
       mf_getstat = fun(Ctrl) when Ctrl =:= DistCtrl ->
                            call_controller(Ctrl, getstat)
                    end,
       mf_setopts = fun(_, _) -> ok end,
       mf_getopts = fun(_, _) -> {ok, []} end,
       f_handshake_complete = fun(Ctrl, Node, DHandle) ->
                                      call_controller(Ctrl,
                                                      {handshake_complete,
                                                       Node, DHandle})
                              end
      }.

%%% =====================================================================
%%% Distribution controller — handshake phase
%%% =====================================================================

spawn_dist_controller(Socket) ->
    spawn_dist_controller(Socket, []).

spawn_dist_controller(Socket, ExtraOpts) ->
    spawn_opt(fun() -> setup_loop(Socket, undefined) end,
              ExtraOpts ++ [{priority, max} | ?SPAWN_OPTS]).

setup_loop(Socket, Sup) ->
    receive
        {Ref, From, {supervisor, Pid}} ->
            Res = link(Pid),
            From ! {Ref, Res},
            setup_loop(Socket, Pid);

        {Ref, From, {send, Packet}} ->
            Res = framed_send(Socket, 2, Packet),
            From ! {Ref, Res},
            setup_loop(Socket, Sup);

        {Ref, From, {recv, _Length, Timeout}} ->
            Res = framed_recv(Socket, 2, Timeout),
            From ! {Ref, Res},
            setup_loop(Socket, Sup);

        {Ref, From, getstat} ->
            From ! {Ref, socket_stats(Socket)},
            setup_loop(Socket, Sup);

        {Ref, From, {handshake_complete, _Node, DHandle}} ->
            From ! {Ref, ok},
            Output = self(),
            Input = spawn_opt(
                      fun() -> input_handler(DHandle, Socket, Sup) end,
                      [link | ?SPAWN_OPTS]),
            erlang:dist_ctrl_input_handler(DHandle, Input),
            Input ! {Output, go},
            process_flag(priority, normal),
            erlang:dist_ctrl_get_data_notification(DHandle),
            output_handler(DHandle, Socket)
    end.

call_controller(Ctrl, Msg) ->
    Ref = erlang:monitor(process, Ctrl),
    Ctrl ! {Ref, self(), Msg},
    receive
        {Ref, Result} ->
            erlang:demonitor(Ref, [flush]),
            Result;
        {'DOWN', Ref, process, Ctrl, Reason} ->
            exit({dist_controller_exit, Reason})
    end.

%%% =====================================================================
%%% Framing — manual length-prefix for handshake (2-byte) and data (4-byte)
%%% =====================================================================

framed_send(Socket, HeaderBytes, Packet) ->
    Size = iolist_size(Packet),
    Header = case HeaderBytes of
                 2 -> <<Size:16>>;
                 4 -> <<Size:32>>
             end,
    socket:send(Socket, [Header, Packet]).

framed_recv(Socket, HeaderBytes, Timeout) ->
    case socket:recv(Socket, HeaderBytes, Timeout) of
        {ok, <<Len:HeaderBytes/big-unit:8>>} ->
            recv_body(Socket, Len, Timeout);
        {error, _} = Err ->
            Err
    end.

recv_body(_Socket, 0, _Timeout) ->
    {ok, <<>>};
recv_body(Socket, Len, Timeout) ->
    socket:recv(Socket, Len, Timeout).

%%% =====================================================================
%%% Output handler — sole writer post-handshake, also handles ticks
%%% =====================================================================

output_handler(DHandle, Socket) ->
    receive
        dist_data ->
            try drain_outgoing(DHandle, Socket)
            catch _:_ -> death_row()
            end,
            output_handler(DHandle, Socket);

        send_tick ->
            case socket:send(Socket, <<0:32>>) of
                ok -> output_handler(DHandle, Socket);
                {error, _} -> death_row()
            end;

        _ ->
            output_handler(DHandle, Socket)
    end.

drain_outgoing(DHandle, Socket) ->
    case erlang:dist_ctrl_get_data(DHandle) of
        none ->
            erlang:dist_ctrl_get_data_notification(DHandle);
        Data ->
            ok = framed_send(Socket, 4, Data),
            drain_outgoing(DHandle, Socket)
    end.

%%% =====================================================================
%%% Input handler — sole reader post-handshake
%%% =====================================================================

input_handler(DHandle, Socket, Sup) ->
    link(Sup),
    receive
        {_Output, go} -> input_loop(DHandle, Socket, <<>>)
    end.

%% Greedy recv: pull whatever bytes are available in the kernel buffer, then
%% extract as many complete frames as we can and carry any remainder into the
%% next iteration. Reduces syscall count under burst traffic versus a pair of
%% exact-size recvs per frame.
input_loop(DHandle, Socket, Buf) ->
    case socket:recv(Socket, 0, infinity) of
        {ok, Bytes} ->
            input_loop(DHandle, Socket,
                       extract_frames(DHandle, <<Buf/binary, Bytes/binary>>));
        {error, _} ->
            exit(connection_closed)
    end.

extract_frames(DHandle, <<Len:32, Body:Len/binary, Rest/binary>>) ->
    deliver(DHandle, Body),
    extract_frames(DHandle, Rest);
extract_frames(_DHandle, Buf) ->
    Buf.

%% Empty body = tick — must not be passed to the distribution machinery.
deliver(_DHandle, <<>>) ->
    ok;
deliver(DHandle, Body) ->
    try erlang:dist_ctrl_put_data(DHandle, Body)
    catch _:_ -> death_row()
    end.

%%% =====================================================================
%%% Stats — derived from socket:info/1 counters. read_pkg/write_pkg are the
%%% counters used by OTP's socket-backed inet implementation for the legacy
%%% recv_cnt/send_cnt values. The dist ticker only requires changing values.
%%% =====================================================================

socket_stats(Socket) ->
    case socket:info(Socket) of
        #{counters := Counters} ->
            Recv = maps:get(read_pkg, Counters, 0),
            Sent = maps:get(write_pkg, Counters, 0),
            {ok, Recv, Sent, 0};
        _ ->
            {ok, 0, 0, 0}
    end.

%%% =====================================================================
%%% Teardown
%%% =====================================================================

death_row() ->
    death_row(connection_closed).

death_row(normal) ->
    death_row();
death_row(Reason) ->
    receive after 5000 -> exit(Reason) end.
