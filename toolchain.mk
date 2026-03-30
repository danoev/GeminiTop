# Gemini cross-compilation settings

CROSS_PREFIX ?= arm-unknown-linux-gnueabihf

CC      = $(CROSS_PREFIX)-gcc
CXX     = $(CROSS_PREFIX)-g++
STRIP   = $(CROSS_PREFIX)-strip
AR      = $(CROSS_PREFIX)-ar

ARCH_FLAGS = -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard
WARN_FLAGS = -Wall -Wno-unused-result
OPT_FLAGS  = -Os

COMMON_CFLAGS = -std=gnu11 $(OPT_FLAGS) $(ARCH_FLAGS) $(WARN_FLAGS) \
                -DLINUX -D_DEFAULT_SOURCE

# Path to libgemini (relative — each Makefile adjusts)
# LIBGEMINI_DIR = ../libgemini
# LIBGEMINI = $(LIBGEMINI_DIR)/libgemini.a
