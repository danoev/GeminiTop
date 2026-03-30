# Gemini custom launcher

include ../toolchain.mk

LIBGEMINI_DIR = ../libgemini
LIBGEMINI     = $(LIBGEMINI_DIR)/libgemini.a
COMMON_DIR    = ../common

CFLAGS = $(COMMON_CFLAGS) -I$(LIBGEMINI_DIR) -I$(COMMON_DIR)
LDFLAGS = -lm

OBJS = geminilauncher.o wifi_overlay.o sysinfo.o app_catalog.o
BIN  = geminilauncher

all: $(BIN)

$(BIN): $(OBJS) $(LIBGEMINI)
	$(CC) $(CFLAGS) $(OBJS) $(LIBGEMINI) -o $@ $(LDFLAGS)
	$(STRIP) $@
	@echo "[launcher] Built $@"
	@ls -la $@

$(LIBGEMINI):
	$(MAKE) -C $(LIBGEMINI_DIR)

geminilauncher.o: geminilauncher.c
	$(CC) $(CFLAGS) -c $< -o $@

wifi_overlay.o: wifi_overlay.c wifi_overlay.h
	$(CC) $(CFLAGS) -c $< -o $@

sysinfo.o: sysinfo.c sysinfo.h
	$(CC) $(CFLAGS) -c $< -o $@

app_catalog.o: $(COMMON_DIR)/app_catalog.c $(COMMON_DIR)/app_catalog.h
	$(CC) $(CFLAGS) -c $< -o $@


clean:
	rm -f *.o $(BIN)

.PHONY: all clean
