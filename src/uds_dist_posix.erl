-module(uds_dist_posix).
-moduledoc false.

-export([ensure_loaded/0, effective_uid/0, peer_effective_uid/1]).

-define(NIF_LOADED_KEY, {?MODULE, nif_loaded}).

effective_uid() ->
    case ensure_loaded() of
        ok -> nif_effective_uid();
        {error, Reason} -> erlang:error(Reason)
    end.

peer_effective_uid(Socket) ->
    case socket:getopt(Socket, otp, fd) of
        {ok, FileDescriptor} ->
            case ensure_loaded() of
                ok -> nif_peer_effective_uid(FileDescriptor);
                {error, _} = Error -> Error
            end;
        {error, Reason} ->
            {error, {socket_fd_unavailable, Reason}}
    end.

ensure_loaded() ->
    case persistent_term:get(?NIF_LOADED_KEY, undefined) of
        undefined ->
            Result = normalize_load_result(load_nif()),
            persistent_term:put(?NIF_LOADED_KEY, Result),
            Result;
        Result ->
            Result
    end.

normalize_load_result(ok) -> ok;
normalize_load_result({error, Reason}) ->
    {error, {posix_helper_unavailable, Reason}}.

load_nif() ->
    case code:priv_dir(uds_dist) of
        {error, Reason} ->
            {error, {priv_dir_unavailable, Reason}};
        PrivDir ->
            Path = filename:join(PrivDir, "uds_dist_posix"),
            case erlang:load_nif(Path, 0) of
                ok ->
                    ok;
                {error, {reload, _}} ->
                    ok;
                {error, Reason} ->
                    {error, {load_failed, Path, Reason}}
            end
    end.

nif_effective_uid() ->
    erlang:nif_error({nif_not_loaded, ?MODULE}).

nif_peer_effective_uid(_FileDescriptor) ->
    erlang:nif_error({nif_not_loaded, ?MODULE}).
