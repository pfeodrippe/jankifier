# lib/libplay.dylib: the games behind a plain C interface (include/play/play.h), with the
# system's clang (ViZDoom and Boost are built with it; only C crosses into jank). Build the
# games in vendor/ first (README.md).
SDK := $(shell xcrun --show-sdk-path)
NLE := vendor/nle
VIZDOOM := vendor/ViZDoom
RETRO := vendor/libretro-fceumm/src/drivers/libretro/libretro-common/include
CXXFLAGS := -std=c++17 -O2 -fPIC -isysroot $(SDK) -Iinclude -I$(RETRO) -I$(VIZDOOM)/include -I$(NLE)/include -I$(NLE)/third_party/converter -I$(NLE)/build/_deps/deboost_context-src/include -Wall -Wno-unused-parameter
LIBS := $(VIZDOOM)/build/bin/libvizdoom.a -L/opt/homebrew/lib -lboost_filesystem -lboost_thread -lboost_chrono

all: lib/libplay.dylib

build/play.o: native/play.cpp include/play/play.h include/play/nes.hpp
	@mkdir -p build
	clang++ $(CXXFLAGS) -c $< -o $@

build/nledl.o: $(NLE)/sys/unix/nledl.c
	@mkdir -p build
	clang -O2 -fPIC -isysroot $(SDK) -I$(NLE)/include -I$(NLE)/build/include -I$(NLE)/build/_deps/deboost_context-src/include -c $< -o $@

lib/libplay.dylib: build/play.o build/nledl.o
	@mkdir -p lib
	clang++ -dynamiclib -isysroot $(SDK) $^ $(LIBS) -install_name @rpath/libplay.dylib -o $@

clean:
	rm -rf build lib
