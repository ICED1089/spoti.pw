# MIT-licensed Signalsmith Stretch + Signalsmith Linear, pinned source only.
# Header-only DSP is compiled into the opt-in DJ stretch bridge.
STRETCH_REPO := https://github.com/Signalsmith-Audio/signalsmith-stretch.git
STRETCH_COMMIT := a670068d9aeb64913331d5cc29337b19a457a7df
LINEAR_REPO := https://github.com/Signalsmith-Audio/linear.git
LINEAR_COMMIT := 146b26f91b48835d665fa0498d64d9617818d27a

SRC := build/stretch
LINEAR := build/linear

.PHONY: all clean
all: $(SRC)/.pinned $(LINEAR)/.pinned

$(SRC)/.pinned:
	@mkdir -p build
	@git clone -q --filter=blob:none $(STRETCH_REPO) $(SRC)
	@cd $(SRC) && git checkout -q $(STRETCH_COMMIT)
	@test -f $(SRC)/LICENSE.txt
	@touch $@

$(LINEAR)/.pinned:
	@mkdir -p build
	@git clone -q --filter=blob:none $(LINEAR_REPO) $(LINEAR)
	@cd $(LINEAR) && git checkout -q $(LINEAR_COMMIT)
	@test -f $(LINEAR)/LICENSE.txt
	@touch $@

clean:
	@rm -rf build
