UPSTREAM_REPO := https://github.com/tillt/BeatIt.git
UPSTREAM_COMMIT := 8d5f9ed80ddcdb8bbaea63d3dea26f137d366d01

BUILD := build
SRC := $(BUILD)/source
OBJ := $(BUILD)/obj/ios
OUT := $(BUILD)/ios
LIB := $(OUT)/libbeatit.a
BUNDLE := $(BUILD)/SpotifyGlassDJ.bundle

SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CXX := $(shell xcrun --sdk iphoneos --find clang++)
AR := $(shell xcrun --sdk iphoneos --find ar)
COMMON := -target arm64-apple-ios16.0 -isysroot $(SDK) -Os -fPIC -fvisibility=hidden -std=c++17 \
	-I$(SRC)/include -I$(SRC)/src -DBEATIT_VERSION=\"spoti-vendor\" -DBEATIT_VERSION_DISPLAY=\"spoti-vendor\" \
	-DBEATIT_VERSION_IS_DEV=0 -DBEATIT_GIT_HASH=\"8d5f9ed\"

# BeatIt's native Core ML + DBN path only. Torch/CLI/plugin loader code is intentionally excluded.
SOURCES_CPP := \
	src/beatit/coreml/preset.cpp \
	src/beatit/audio/dsp.cpp \
	src/beatit/audio/features.cpp \
	src/beatit/runtime/logging.cpp \
	src/beatit/post/pipeline.cpp \
	src/beatit/post/helpers.cpp \
	src/beatit/post/dbn_run.cpp \
	src/beatit/post/dbn_apply.cpp \
	src/beatit/post/grid_anchor.cpp \
	src/beatit/post/grid_fill.cpp \
	src/beatit/post/grid_phase_select.cpp \
	src/beatit/post/grid_synthesize.cpp \
	src/beatit/post/grid_tempo_decision.cpp \
	src/beatit/post/logits.cpp \
	src/beatit/post/result_ops.cpp \
	src/beatit/post/tempo_fit.cpp \
	src/beatit/post/window.cpp \
	src/beatit/post/window_select.cpp \
	src/beatit/dbn/beatit.cpp \
	src/beatit/dbn/calmdad.cpp \
	src/beatit/dbn/calmdad_sparse.cpp

SOURCES_MM := \
	src/beatit/inference/coreml/inference.mm \
	src/beatit/inference/coreml/model_utils.mm

OBJECTS_CPP := $(patsubst %.cpp,$(OBJ)/cpp/%.o,$(SOURCES_CPP))
OBJECTS_MM := $(patsubst %.mm,$(OBJ)/mm/%.o,$(SOURCES_MM))
OBJECTS := $(OBJECTS_CPP) $(OBJECTS_MM)

.PHONY: all clean source
all: $(LIB) $(BUNDLE)

source: $(SRC)/.pinned

$(SRC)/.pinned:
	@mkdir -p $(BUILD)
	@rm -rf $(SRC)
	@git clone -q --filter=blob:none $(UPSTREAM_REPO) $(SRC)
	@cd $(SRC) && git checkout -q $(UPSTREAM_COMMIT)
	@touch $@

$(OBJ)/cpp/%.o: $(SRC)/.pinned
	@mkdir -p $(dir $@)
	@$(CXX) $(COMMON) -c $(SRC)/$*.cpp -o $@

$(OBJ)/mm/%.o: $(SRC)/.pinned
	@mkdir -p $(dir $@)
	@$(CXX) $(COMMON) -fobjc-arc -c $(SRC)/$*.mm -o $@

$(LIB): $(OBJECTS)
	@mkdir -p $(OUT)
	@rm -f $@
	@$(AR) rcs $@ $(OBJECTS)

$(BUNDLE): $(SRC)/.pinned
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)
	@cp -R $(SRC)/models/BeatThis_small0.mlpackage $(BUNDLE)/BeatThis_small0.mlpackage
	@cp $(SRC)/LICENSE $(BUNDLE)/BeatIt-LICENSE.txt
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>CFBundleIdentifier</key><string>pw.spoti.djbeat</string>' \
	  '<key>CFBundleName</key><string>SpotifyGlassDJ</string>' \
	  '<key>CFBundlePackageType</key><string>BNDL</string>' \
	  '<key>CFBundleShortVersionString</key><string>1</string>' \
	  '<key>CFBundleVersion</key><string>1</string>' \
	  '</dict></plist>' > $(BUNDLE)/Info.plist

clean:
	@rm -rf $(OBJ) $(OUT) $(BUNDLE)
