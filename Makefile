CC ?= cc
CFLAGS ?= -O2
CFLAGS += -fPIC -Wall -Wextra -I$(ERTS_INCLUDE_DIR)
CFLAGS += $(STRICT_CFLAGS)
LDFLAGS += -shared

ifeq ($(shell uname -s),Darwin)
LDFLAGS += -undefined dynamic_lookup
endif

PRIV_DIR := $(MIX_APP_PATH)/priv
NIF := $(PRIV_DIR)/uds_dist_posix.so
SRC := c_src/uds_dist_posix.c
ifneq ($(strip $(ERTS_INCLUDE_DIR)),)
NIF_DEPS := $(ERTS_INCLUDE_DIR)/erl_nif.h
endif

.PHONY: all clean

all: $(NIF)

$(NIF): $(SRC) $(NIF_DEPS)
	test -n "$(ERTS_INCLUDE_DIR)" || { echo "ERTS_INCLUDE_DIR is required" >&2; exit 1; }
	mkdir -p "$(PRIV_DIR)"
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o "$@" "$<"

clean:
	$(RM) "$(NIF)"
