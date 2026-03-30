# Gemini — top-level Makefile

.PHONY: all libgemini orchestrator launcher doom clean

all: libgemini orchestrator launcher doom

libgemini:
	$(MAKE) -C libgemini

orchestrator:
	$(MAKE) -C orchestrator

launcher: libgemini
	$(MAKE) -C launcher

doom: libgemini
	$(MAKE) -C apps/doom

clean:
	$(MAKE) -C libgemini clean
	$(MAKE) -C orchestrator clean
	$(MAKE) -C launcher clean
	$(MAKE) -C apps/doom clean
