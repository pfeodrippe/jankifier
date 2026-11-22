# Builds lib/libinkling.dylib and bin/inkling with jank's clang and libc++, so
# the C++ types in include/inkling/inkling.hpp are the ones jank uses.
JANK_PREFIX ?= $(shell dirname $$(dirname $$(readlink -f $$(command -v jank))))/lib/jank/0.1
CXX := $(JANK_PREFIX)/bin/clang++
SDK := $(shell xcrun --show-sdk-path)
CXXFLAGS := -std=c++20 -O3 -mcpu=native -ffp-contract=off -fPIC -isysroot $(SDK) -Iinclude -Wall -Wextra -Wno-unused-parameter
LDFLAGS := -nostdlib++ -L$(JANK_PREFIX)/lib -lc++ -lc++abi -Wl,-rpath,$(JANK_PREFIX)/lib

SOURCES := native/model.cpp native/tokenizer.cpp native/cpu.cpp native/check.cpp
OBJECTS := $(SOURCES:native/%.cpp=build/%.o) build/metal.o
HEADERS := include/inkling/inkling.hpp native/internal.hpp native/json.hpp native/unicode_table.inc
FRAMEWORKS := -framework Metal -framework Foundation

all: lib/libinkling.dylib bin/inkling

build/%.o: native/%.cpp $(HEADERS)
	@mkdir -p build
	@rm -f $@
	$(CXX) $(CXXFLAGS) -c $< -o $@ 2>&1 | grep -v '^dyld' ; test -f $@

build/metal.o: native/metal.mm native/kernels.metal $(HEADERS)
	@mkdir -p build
	@rm -f $@
	$(CXX) $(CXXFLAGS) -fobjc-arc -fno-objc-msgsend-selector-stubs -fno-objc-msgsend-class-selector-stubs -c $< -o $@ 2>&1 | grep -v '^dyld' ; test -f $@

lib/libinkling.dylib: $(OBJECTS)
	@mkdir -p lib
	@rm -f $@
	$(CXX) -dynamiclib -isysroot $(SDK) $(OBJECTS) $(LDFLAGS) $(FRAMEWORKS) -install_name @rpath/libinkling.dylib -o $@ 2>&1 | grep -v '^dyld\|libunwind' ; test -f $@

bin/inkling: native/cli.cpp lib/libinkling.dylib $(HEADERS)
	@mkdir -p bin
	@rm -f $@
	$(CXX) $(CXXFLAGS) native/cli.cpp -Llib -linkling $(LDFLAGS) -Wl,-rpath,@executable_path/../lib -o $@ 2>&1 | grep -v '^dyld\|libunwind' ; test -f $@

native/unicode_table.inc: tools/gen_unicode.py
	python3 -I tools/gen_unicode.py > $@

clean:
	rm -rf build lib bin

.PHONY: all clean
