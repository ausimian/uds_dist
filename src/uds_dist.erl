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
`lib/kernel/examples` with several simplifications: pure-Erlang via the
`socket` NIF rather than `gen_tcp`, distribution protocol version 6
only, abstract namespace support on Linux, and socket-path resolution
driven by application configuration (the `:socket_dir` value on the
`:uds_dist` application environment).
""".

-export([listen/1, accept/1, accept_connection/5,
         setup/5, close/1, select/1, address/0]).
-export([setopts/2, getopts/2]).
-export([accept_loop/2, accept_handshake/2,
         accept_supervisor/6, setup_supervisor/5]).

%% Exported for testing.
-export([resolve_path/1, strip_host/1, abstract_supported/0]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").

-define(ERL_DIST_VER, 6).
-define(SPAWN_OPTS, [{message_queue_data, off_heap}, {fullsweep_after, 0}]).
-define(BACKLOG, 128).

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
    Path = resolve_path(atom_to_list(NameAtom)),
    case open_and_bind(Path) of
        {ok, Listen} ->
            {ok, {Listen, net_address(sockaddr_to_address(Path)), creation()}};
        {error, _} = Error ->
            Error
    end.

-doc false.
accept(ListenSocket) ->
    spawn_opt(?MODULE, accept_loop, [self(), ListenSocket],
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
    socket:close(ListenSocket).

-doc false.
setopts(_ListenSocket, _Options) ->
    ok.

-doc false.
getopts(_ListenSocket, _Options) ->
    {ok, []}.

%%% =====================================================================
%%% Path resolution and helpers
%%% =====================================================================

%% Resolve a node-name-without-host to a sockaddr_un path (binary). Reads
%% the configured socket_dir from the application environment. A leading
%% "@" on the configured dir selects the Linux abstract namespace.
-doc false.
resolve_path(Name) when is_list(Name) ->
    %% Ensure the .app file is loaded so that -uds_dist socket_dir Path
    %% args (resolved into app env at load time) are visible. Releases
    %% load us via the boot script; ad-hoc invocations may not have.
    _ = application:load(uds_dist),
    case application:get_env(uds_dist, socket_dir, ".") of
        [$@ | Rest] ->
            true = abstract_supported() orelse
                erlang:error({abstract_sockets_unsupported, os:type()}),
            %% Abstract paths are signalled by a leading NUL byte and live
            %% in the kernel namespace, not the filesystem.
            iolist_to_binary([0, Rest, "/", Name]);
        Dir ->
            iolist_to_binary(filename:join(Dir, Name ++ ".sock"))
    end.

-doc false.
abstract_supported() ->
    case os:type() of
        {unix, linux} -> true;
        _ -> false
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
            ok = socket:listen(S, ?BACKLOG),
            {ok, S};
        {error, eaddrinuse} ->
            socket:close(S),
            handle_eaddrinuse(Path);
        {error, _} = Err ->
            socket:close(S),
            Err
    end.

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
            _ = file:delete(Path, [raw]),
            open_and_bind(Path)
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
accept_loop(Kernel, ListenSocket) ->
    case socket:accept(ListenSocket) of
        {ok, Socket} ->
            %% Hand the handshake to a per-connection helper so the
            %% loop can immediately re-enter socket:accept/1. Without
            %% this the loop is serialised by the kernel handshake
            %% round-trip and the listen backlog can overflow under
            %% bursts of concurrent dialers.
            _ = spawn_opt(?MODULE, accept_handshake, [Kernel, Socket],
                          [{priority, max} | ?SPAWN_OPTS]),
            accept_loop(Kernel, ListenSocket);
        {error, closed} ->
            exit(closing_connection);
        Error ->
            exit(Error)
    end.

-doc false.
accept_handshake(Kernel, Socket) ->
    DistCtrl = spawn_dist_controller(Socket),
    Kernel ! {accept, self(), DistCtrl, local, stream},
    receive
        {Kernel, controller, SupervisorPid} ->
            call_controller(DistCtrl, {supervisor, SupervisorPid}),
            SupervisorPid ! {self(), controller};
        {Kernel, unsupported_protocol} ->
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
    {ok, Socket} = socket:open(local, stream, default),
    case socket:connect(Socket, sockaddr(Path)) of
        ok ->
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
            dist_util:handshake_we_started(HSData);
        {error, _} ->
            socket:close(Socket),
            ?shutdown(Node)
    end.

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
    spawn_opt(fun() -> setup_loop(Socket, undefined) end,
              [{priority, max} | ?SPAWN_OPTS]).

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
%% exact-size recvs per frame. BEAM's writable-binary optimisation keeps the
%% Buf append amortised O(bytes received).
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
%%% Stats — derived from socket:info/1 counters. The values do not match
%%% gen_tcp's send_cnt/recv_cnt one-to-one (these are byte counts, not
%%% packet counts) but the dist ticker only cares that the numbers move
%%% when traffic flows.
%%% =====================================================================

socket_stats(Socket) ->
    case socket:info(Socket) of
        #{counters := Counters} ->
            Recv = maps:get(read_byte, Counters, 0),
            Sent = maps:get(write_byte, Counters, 0),
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
