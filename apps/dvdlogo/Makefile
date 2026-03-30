include ../../toolchain.mk

LIBGEMINI_DIR = ../../libgemini
LIBGEMINI     = $(LIBGEMINI_DIR)/libgemini.a

OBJDIR = build
OUTPUT = dvdlogo
ASSET_PNG := $(wildcard logo.png)
ASSET_C = $(OBJDIR)/logo_asset.c
ASSET_H = $(OBJDIR)/logo_asset.h

CFLAGS = $(COMMON_CFLAGS) -I$(LIBGEMINI_DIR) -I$(OBJDIR)
LDFLAGS = -ldl

OBJS = $(OBJDIR)/dvdlogo.o $(OBJDIR)/logo_asset.o

all: $(OUTPUT)
	@echo ""
	@echo "=== DVD LOGO BUILD COMPLETE ==="
	@ls -la $(OUTPUT)

$(OUTPUT): $(OBJS) $(LIBGEMINI)
	$(CC) $(CFLAGS) $(OBJS) $(LIBGEMINI) -o $@ $(LDFLAGS)
	$(STRIP) $@

$(LIBGEMINI):
	$(MAKE) -C $(LIBGEMINI_DIR)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(ASSET_C): gen_logo_asset.py $(ASSET_PNG) | $(OBJDIR)
	python3 gen_logo_asset.py --input "$(ASSET_PNG)" --output-c "$(ASSET_C)" --output-h "$(ASSET_H)"

$(ASSET_H): $(ASSET_C)

$(OBJDIR)/dvdlogo.o: dvdlogo.c $(ASSET_H) | $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJDIR)/logo_asset.o: $(ASSET_C) $(ASSET_H) | $(OBJDIR)
	$(CC) $(CFLAGS) -c $(ASSET_C) -o $@

clean:
	rm -rf $(OBJDIR) $(OUTPUT)

.PHONY: all clean
