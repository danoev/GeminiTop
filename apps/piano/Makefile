include ../../toolchain.mk

LIBGEMINI_DIR = ../../libgemini
LIBGEMINI     = $(LIBGEMINI_DIR)/libgemini.a

CFLAGS = $(COMMON_CFLAGS) -I$(LIBGEMINI_DIR)
LDFLAGS = -lm -ldl

OBJDIR = build
OUTPUT = piano
OBJS = $(OBJDIR)/piano.o

all: $(OUTPUT)
	@echo ""
	@echo "=== PIANO BUILD COMPLETE ==="
	@ls -la $(OUTPUT)

$(OUTPUT): $(OBJS) $(LIBGEMINI)
	$(CC) $(CFLAGS) $(OBJS) $(LIBGEMINI) -o $@ $(LDFLAGS)
	$(STRIP) $@

$(LIBGEMINI):
	$(MAKE) -C $(LIBGEMINI_DIR)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJDIR)/piano.o: piano.c | $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(OBJDIR) $(OUTPUT)

.PHONY: all clean
