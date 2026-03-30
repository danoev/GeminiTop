# DOOM for Gemini head unit — cross-compiles doomgeneric with libgemini integration code
#
# The doomgeneric engine source and doom1.wad are downloaded automatically
# by fetch_source.sh if not already present.  Our Gemini integration code
# lives in gemini/ and is the only code we maintain.

include ../../toolchain.mk

LIBGEMINI_DIR = ../../libgemini
LIBGEMINI     = $(LIBGEMINI_DIR)/libgemini.a

CFLAGS = $(COMMON_CFLAGS) \
         -Wno-pointer-sign \
         -DNORMALUNIX -DLINUX -D_DEFAULT_SOURCE \
         -DDOOMGENERIC_RESX=640 -DDOOMGENERIC_RESY=400 \
         -DFEATURE_SOUND -DGEMINI_SOUND

LDFLAGS = -lm -ldl

SRCDIR = doomgeneric
OBJDIR = build
OUTPUT = doom

# All DOOM engine source files
SRC_DOOM = dummy.c am_map.c doomdef.c doomstat.c dstrings.c \
           d_event.c d_items.c d_iwad.c d_loop.c d_main.c d_mode.c d_net.c \
           f_finale.c f_wipe.c g_game.c \
           hu_lib.c hu_stuff.c \
           info.c i_cdmus.c i_endoom.c i_joystick.c i_scale.c \
           i_sound.c i_system.c i_timer.c i_input.c i_video.c \
           memio.c m_argv.c m_bbox.c m_cheat.c m_config.c m_controls.c \
           m_fixed.c m_menu.c m_misc.c m_random.c \
           p_ceilng.c p_doors.c p_enemy.c p_floor.c p_inter.c p_lights.c \
           p_map.c p_maputl.c p_mobj.c p_plats.c p_pspr.c p_saveg.c \
           p_setup.c p_sight.c p_spec.c p_switch.c p_telept.c p_tick.c p_user.c \
           r_bsp.c r_data.c r_draw.c r_main.c r_plane.c r_segs.c r_sky.c r_things.c \
           sha1.c sounds.c statdump.c st_lib.c st_stuff.c s_sound.c \
           tables.c v_video.c wi_stuff.c \
           w_checksum.c w_file.c w_main.c w_wad.c w_file_stdc.c \
           z_zone.c doomgeneric.c \
           icon.c

# Our Gemini integration sources
SRC_PLATFORM = gemini_platform.c
SRC_SOUND    = gemini_audio.c

OBJS_DOOM     = $(addprefix $(OBJDIR)/, $(SRC_DOOM:.c=.o))
OBJS_PLATFORM = $(OBJDIR)/gemini_platform.o
OBJS_SOUND    = $(OBJDIR)/gemini_audio.o

OBJS = $(OBJS_DOOM) $(OBJS_PLATFORM) $(OBJS_SOUND)

# Use recursive make: fetch sources first, then build.
# This avoids Make failing to resolve doomgeneric/*.c before they exist.
all:
	@bash fetch_source.sh
	@$(MAKE) --no-print-directory build_doom

build_doom: $(OUTPUT)
	@echo ""
	@echo "=== DOOM BUILD COMPLETE ==="
	@ls -la $(OUTPUT)

$(OUTPUT): $(OBJS) $(LIBGEMINI)
	@echo "[Linking doom]"
	$(CC) $(CFLAGS) $(OBJS) $(LIBGEMINI) -o $(OUTPUT) $(LDFLAGS)
	$(STRIP) $(OUTPUT)

$(LIBGEMINI):
	$(MAKE) -C $(LIBGEMINI_DIR)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJS_DOOM): $(OBJDIR)/%.o: $(SRCDIR)/%.c | $(OBJDIR)
	@echo "[CC] $<"
	@$(CC) $(CFLAGS) -I$(SRCDIR) -c $< -o $@

$(OBJDIR)/gemini_platform.o: gemini/gemini_platform.c | $(OBJDIR)
	@echo "[CC] $< (Gemini platform layer)"
	@$(CC) $(CFLAGS) -I$(SRCDIR) -I$(LIBGEMINI_DIR) -c $< -o $@

$(OBJDIR)/gemini_audio.o: gemini/gemini_audio.c | $(OBJDIR)
	@echo "[CC] $< (Gemini audio module)"
	@$(CC) $(CFLAGS) -I$(SRCDIR) -I$(LIBGEMINI_DIR) -c $< -o $@

clean:
	rm -rf $(OBJDIR) $(OUTPUT)

.PHONY: all build_doom clean
