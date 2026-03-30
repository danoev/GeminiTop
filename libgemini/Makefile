# libgemini — Gemini hardware abstraction layer

include ../toolchain.mk

CFLAGS = $(COMMON_CFLAGS)

SRCS = gemini_video.c gemini_input.c gemini_audio.c gemini_system.c gemini_draw.c gemini_log.c gemini_mixer.c
OBJS = $(SRCS:.c=.o)
LIB  = libgemini.a

all: $(LIB)

$(LIB): $(OBJS)
	$(AR) rcs $@ $^
	@echo "[libgemini] Built $@"

%.o: %.c gemini.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(LIB)

.PHONY: all clean
