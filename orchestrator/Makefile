# Gemini native orchestrator

include ../toolchain.mk

COMMON_DIR = ../common

CFLAGS = $(COMMON_CFLAGS) -I$(COMMON_DIR)
LDFLAGS =

BIN  = geminiorchestrator
OBJS = geminiorchestrator.o app_catalog.o

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(CFLAGS) $(OBJS) -o $@ $(LDFLAGS)
	$(STRIP) $@
	@echo "[orchestrator] Built $@"
	@ls -la $@

geminiorchestrator.o: geminiorchestrator.c
	$(CC) $(CFLAGS) -c $< -o $@

app_catalog.o: $(COMMON_DIR)/app_catalog.c $(COMMON_DIR)/app_catalog.h
	$(CC) $(CFLAGS) -c $< -o $@


clean:
	rm -f *.o $(BIN)

.PHONY: all clean
