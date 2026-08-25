# Build and measurement harness for the Pocket PC Engine core.
#
# Quartus, containerised (see tools/podman/README.md):
#
#   make pce                    build -> build/pce/{report.txt,build.log,work/}
#   make pce BUILD_NAME=foo     build into build/foo/ instead (compare two trees)
#   make pce NO_SIGNALTAP=1     build without the qsf's SignalTap instrumentation
#   make pce SEED=2             re-run the fitter with a different placement seed
#   make pce SKIP_COMPILE=1     re-report existing outputs (no Quartus run)
#   make report                 regenerate build/pce/report.txt from existing outputs
#   make shell                  interactive shell in the Quartus container
#   make compare A=pce B=vanfanel   resource and timing delta between two builds
#   make clean                  remove build/

PODMAN  ?= podman
IMAGE   ?= localhost/pocket-quartus:25.1std
REV     ?= pce_pocket
HARNESS := tools/podman

.PHONY: pce report compare shell clean

pce:
	PODMAN=$(PODMAN) IMAGE=$(IMAGE) REV=$(REV) SEED=$(SEED) BUILD_NAME=$(BUILD_NAME) \
	SKIP_COMPILE=$(SKIP_COMPILE) NO_SIGNALTAP=$(NO_SIGNALTAP) \
	FITTER_EFFORT="$(FITTER_EFFORT)" NPROC="$(NPROC)" \
	STRICT_TIMING=$(STRICT_TIMING) $(HARNESS)/build.sh

report:
	REV=$(REV) BUILD_NAME=$(BUILD_NAME) $(HARNESS)/report.sh

shell:
	$(PODMAN) run --rm -it --userns=keep-id --security-opt label=disable \
		-v "$(CURDIR)/build/$(or $(BUILD_NAME),pce)/work:/work" -w /work/projects -e HOME=/tmp $(IMAGE) bash

clean:
	rm -rf build

compare:
	REV=$(REV) $(HARNESS)/compare.sh $(A) $(B)
