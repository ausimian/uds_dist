#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <erl_nif.h>
#include <erl_driver.h>

#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name)
{
    return enif_make_atom(env, name);
}

static ERL_NIF_TERM error(ErlNifEnv *env, ERL_NIF_TERM reason)
{
    return enif_make_tuple2(env, atom(env, "error"), reason);
}

static ERL_NIF_TERM posix_error(ErlNifEnv *env, int error_number)
{
    return error(env, atom(env, erl_errno_id(error_number)));
}

static ERL_NIF_TERM effective_uid(ErlNifEnv *env,
                                  int argc,
                                  const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_uint64(env, (ErlNifUInt64)geteuid());
}

static ERL_NIF_TERM peer_effective_uid(ErlNifEnv *env,
                                       int argc,
                                       const ERL_NIF_TERM argv[])
{
    int fd;
    uid_t uid;

    if (argc != 1 || !enif_get_int(env, argv[0], &fd) || fd < 0) {
        return enif_make_badarg(env);
    }

#if defined(__linux__)
    {
        struct ucred credentials;
        socklen_t length = sizeof(credentials);

        if (getsockopt(fd,
                       SOL_SOCKET,
                       SO_PEERCRED,
                       &credentials,
                       &length) != 0) {
            return posix_error(env, errno);
        }

        if (length != sizeof(credentials) || credentials.uid == (uid_t)-1) {
            return error(env, atom(env, "enotconn"));
        }

        uid = credentials.uid;
    }
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) ||     \
    defined(__OpenBSD__) || defined(__DragonFly__)
    {
        gid_t gid;

        if (getpeereid(fd, &uid, &gid) != 0) {
            return posix_error(env, errno);
        }
    }
#else
    return error(env, atom(env, "enotsup"));
#endif

    return enif_make_tuple2(env,
                            atom(env, "ok"),
                            enif_make_uint64(env, (ErlNifUInt64)uid));
}

static ErlNifFunc nif_functions[] = {
    {"nif_effective_uid", 0, effective_uid, 0},
    {"nif_peer_effective_uid", 1, peer_effective_uid, 0}
};

ERL_NIF_INIT(uds_dist_posix, nif_functions, NULL, NULL, NULL, NULL)
