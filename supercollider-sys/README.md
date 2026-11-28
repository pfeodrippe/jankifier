# supercollider-sys

SuperCollider's audio server as a library for jank: `libscsynth` (SuperCollider 3.14.1), its 26
UGen plugins (SinOsc, Out, EnvGen and the rest) and its C headers. jank calls SC's C API
directly; there's no wrapper. The server then runs inside the jank program: commands go in with
`World_SendPacket`, and the program can read the server's buses and buffers directly.

## Getting the source

SuperCollider is a submodule, with four of its own that the build needs (nova-simd, nova-tt,
portaudio, yaml-cpp; not Ableton Link, hidapi or the editors):

```sh
git submodule update --init supercollider-sys/lib/supercollider
cd supercollider-sys/lib/supercollider
git submodule update --init external_libraries/nova-simd external_libraries/nova-tt \
  external_libraries/yaml-cpp external_libraries/portaudio/portaudio_submodule
```

The build needs CMake, Ninja (on macOS; see below) and libsndfile: `brew install cmake ninja
libsndfile`. On Linux, also JACK, which is scsynth's audio API there, and FFTW (not tried yet).

## Running the example

```sh
cd supercollider-sys/example && lein run
```

The package is on Clojars as `io.github.pfeodrippe/supercollider-sys`. To try a change to it
before it's published, `lein install` it first.

The first run builds SuperCollider (about 15 s on 16 cores); later runs use jank-build's cache.
The example has no audio device to use, so it renders a score (non-realtime synthesis) into a
file and reads the samples back. The score loads a SynthDef that the example writes byte by
byte, SinOsc into Out with a `freq` control, and plays it at 1000 Hz. It fails unless it gets
that sine back:

```
rendered 2432 frames at 48 kHz
peak: 1.0
frequency from zero crossings (asked for 1000 Hz): 999.9998978206195
```

## What a program gets

- Include directories for `SC_WorldOptions.h` (`World_New`, `World_SendPacket`,
  `World_OpenUDP`, `World_NonRealTimeSynthesis`, `World_Cleanup`, `SetPrintFunc`), and for
  the plugin interface (`SC_PlugIn.h`, `SC_InterfaceTable.h`, `SC_World.h`), which UGens
  compile against.
- `libscsynth`, linked.
- `SUPERCOLLIDER_SYS_PLUGIN_DIR`, a string literal with the plugins' folder, for
  `WorldOptions::mUGensPluginPath`.

A world started with `mRealTime = false` has no audio driver: `World_SendPacket` returns false
there, and the only way to run it is `World_NonRealTimeSynthesis` with a score file, as the
example does. With `mRealTime = true` it opens the audio device (CoreAudio on macOS) and takes
packets from any thread.

In jank, C++ scopes are written with dots: `cpp/supercollider_sys_example.render` calls
`supercollider_sys_example::render`. (With `::`, calls fail with "There is no call operator".)

## How it's built

`jank-build.bb` configures SuperCollider with only the server's parts (no Qt, IDE, supernova,
Link or HID; `LIBSCSYNTH=ON`) and builds only `libscsynth` and the plugin targets. SC's install
step would also assemble sclang and, on macOS, SuperCollider.app. It copies the library, the
plugins and the headers into the output folder.

jank-build runs the build in a sandbox, and three settings are there for it:

- On macOS the compilers and the SDK are given by their real paths. `/usr/bin/cc`, `c++` and
  `make` are shims that ask xcodebuild where the tools are, and xcodebuild can't start inside
  the sandbox. That's also why the build uses Ninja when it's installed: CMake's default
  Makefiles would run `make` through the same shim.
- ccache is off: it keeps its cache in the home folder, which the sandbox closes.
- The install prefix is in the build folder: on macOS each plugin is also copied into an app
  bundle under it as it's built.

The server is built optimized even for a debug build of the program (`RelWithDebInfo`), since
a debug server can't keep up with much audio.

`:verbatim-paths` lists what configuring and building reads from SuperCollider's tree, 83 MB
(the jar is 16 MB). CMake configures sclang too, so `lang`, `SCDoc` and `editors` are there,
although only the server's targets are built.

## License

SuperCollider is GPL-3.0-or-later. A program that links `libscsynth` into its own process is a
combined work under the GPL when it's distributed; one that talks to a separate `scsynth` over
OSC isn't.
