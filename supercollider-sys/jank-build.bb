(require '[babashka.fs :as fs]
         '[babashka.process :as proc]
         '[clojure.string :as string]
         '[jank.build.cmake :as cmake]
         '[jank.build.util :as util])

(defn mac-toolchain
  "On macOS, the compilers and SDK by their real paths. /usr/bin/cc, c++ and make are shims that
  ask xcodebuild where the tools are, and xcodebuild can't start inside jank-build's sandbox."
  []
  (let [dev    (string/trim (:out (proc/shell {:out :string} "xcode-select" "-p")))
        xcode? (fs/exists? (fs/path dev "Toolchains"))
        bin    (if xcode? (fs/path dev "Toolchains" "XcodeDefault.xctoolchain" "usr" "bin") (fs/path dev "usr" "bin"))
        sdk    (if xcode?
                 (fs/path dev "Platforms" "MacOSX.platform" "Developer" "SDKs" "MacOSX.sdk")
                 (fs/path dev "SDKs" "MacOSX.sdk"))]
    {"CMAKE_C_COMPILER"   (str (fs/path bin "clang"))
     "CMAKE_CXX_COMPILER" (str (fs/path bin "clang++"))
     "CMAKE_OSX_SYSROOT"  (str sdk)}))

;; SuperCollider's server as a shared library (libscsynth) and its UGen plugins, from
;; lib/supercollider. SC's install step would also assemble sclang and, on macOS,
;; SuperCollider.app, so this builds only those targets and copies them into the output folder.
(let [src-dir   (str (fs/path (:src-dir *input*) "lib" "supercollider"))
      build-dir (:build-dir *input*)
      out-dir   (:out-dir *input*)
      ;; UIUGens (mouse and keyboard) needs X11 on Linux, which is left out there.
      plugins   (cond-> ["BinaryOpUGens" "ChaosUGens" "DelayUGens" "DemandUGens" "DemoUGens"
                         "DiskIO_UGens" "DynNoiseUGens" "FFT_UGens" "FilterUGens" "GendynUGens"
                         "GrainUGens" "IOUGens" "LFUGens" "ML_UGens" "MulAddUGens" "NoiseUGens"
                         "OscUGens" "PV_ThirdParty" "PanUGens" "PhysicalModelingUGens"
                         "ReverbUGens" "TestUGens" "TriggerUGens" "UnaryOpUGens"
                         "UnpackFFTUGens"]
                  (util/mac?) (conj "UIUGens"))]
  ;; jank.build.cmake's `cmake`, with Ninja when it's there: inside jank-build's macOS sandbox,
  ;; with Xcode as the developer directory, `make` is looked up through xcodebuild, which fails.
  (let [defines (merge (cmake/default-defines *input*)
                       {;; Optimized even for a debug build of the program: a debug server
                        ;; can't keep up with much audio. RelWithDebInfo keeps its symbols.
                        "CMAKE_BUILD_TYPE" (if (pos? (:optimization-level *input*))
                                             "Release"
                                             "RelWithDebInfo")
                        "LIBSCSYNTH"       true
                        "SC_QT"            false
                        "SC_IDE"           false
                        "SUPERNOVA"        false
                        "SC_ABLETON_LINK"  false
                        "SC_HIDAPI"        false
                        "SCLANG_SERVER"    false
                        "ENABLE_TESTSUITE" false
                        "INSTALL_HELP"     false
                        ;; ccache keeps its cache in the home folder, which the sandbox closes.
                        "USE_CCACHE"       false
                        "NO_X11"           (util/linux?)
                        ;; No network discovery (Avahi) on Linux: a server in a program's own
                        ;; process doesn't announce itself, and libscsynth then links nothing
                        ;; more than libsndfile, JACK and FFTW there.
                        "NO_AVAHI"         (util/linux?)
                        ;; On macOS each plugin is also copied into an app bundle under the
                        ;; install prefix as it's built: keep that out of the output.
                        "CMAKE_INSTALL_PREFIX" (str (fs/path build-dir "install"))}
                       (when (util/mac?) (mac-toolchain)))]
    (proc/shell (concat ["cmake"]
                        (when (fs/which "ninja") ["-G" "Ninja"])
                        (map (fn [[k v]] (str "-D" k "=" v)) defines)
                        ["-B" build-dir src-dir]))
    (proc/shell (concat ["cmake" "--build" build-dir "--parallel" "--target" "libscsynth"] plugins)))

  (let [lib-dir    (fs/path out-dir "lib")
        plugin-dir (fs/path out-dir "plugins")]
    (fs/create-dirs lib-dir)
    (fs/create-dirs plugin-dir)
    ;; libscsynth.dylib and its versioned names (symlinks), or libscsynth.so*.
    (doseq [f (fs/glob (fs/path build-dir "server" "scsynth") "libscsynth*")]
      (fs/copy f (fs/path lib-dir (fs/file-name f)) {:nofollow-links true}))
    (doseq [f (fs/glob (fs/path build-dir "server" "plugins") (if (util/mac?) "*.scx" "*.so"))]
      (fs/copy f (fs/path plugin-dir (fs/file-name f))))
    ;; The C API (server/SC_WorldOptions.h) and what plugins compile against (plugin_interface).
    (doseq [d ["plugin_interface" "common" "server"]]
      (fs/copy-tree (fs/path src-dir "include" d) (fs/path out-dir "include" d))
      (util/include-dir (str "include/" d)))
    (util/link-dir "lib")
    (util/link-library "scsynth")
    ;; For WorldOptions::mUGensPluginPath.
    (util/define "SUPERCOLLIDER_SYS_PLUGIN_DIR" (str "\"" plugin-dir "\""))))
