#!/bin/sh
# Installs the build of jank's main published at cache.jank-lang.org beside the installed jank,
# named by the date it was published (jank-YYYY-MM-DD), so the repros can be run on it and on
# the installed jank side by side. Usage: ./install-jank-main.sh
#
# It makes:
#   ~/.local/share/jank/DATE/            the build (bin/jank, lib/jank/...) and SOURCE (where from)
#   ~/.local/share/jank/DATE/shim/jank   that build with its own cache (~/.cache/jank-DATE) and,
#                                        under lein-jank, its own compile folder (target/jank-DATE)
#   ~/.local/bin/jank-DATE               the shim, to run directly or give as $JANK
#   ~/.local/bin/lein-jank-DATE          lein with the shim first on the PATH: lein-jank runs
#                                        `jank` from the PATH, so its tasks use this build
#   ~/.local/bin/jank-main, lein-jank-main   the same for the newest one installed
#
# The shim keeps two things apart from the installed jank: jank's own cache (builds with the same
# version share its key, and so a precompiled header), and a project's compiled modules (jank
# loads a module's .o file without checking which jank compiled it).
set -eu

URL=https://cache.jank-lang.org/jank_0.1-1_aarch64.tar.gz
ROOT=$HOME/.local/share/jank
BIN=$HOME/.local/bin

tmp=$(mktemp -d "${TMPDIR:-/tmp}/jank-main.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "downloading $URL"
curl -fL --retry 2 -D "$tmp/headers" -o "$tmp/jank.tar.gz" "$URL"
modified=$(grep -i '^last-modified:' "$tmp/headers" | tail -1 | cut -d' ' -f2- | tr -d '\r')
etag=$(grep -i '^etag:' "$tmp/headers" | tail -1 | cut -d' ' -f2- | tr -d '\r')
sha=$(shasum -a 256 "$tmp/jank.tar.gz" | cut -d' ' -f1)
name=$(date -j -u -f '%a, %d %b %Y %H:%M:%S GMT' "$modified" +%Y-%m-%d)

# Two builds published the same day: the second is named by its time too.
dir=$ROOT/$name
if [ -e "$dir" ]; then
  if grep -q "$sha" "$dir/SOURCE" 2>/dev/null; then
    echo "this build is already installed: $dir"
    exit 0
  fi
  name=$(date -j -u -f '%a, %d %b %Y %H:%M:%S GMT' "$modified" +%Y-%m-%d-%H%M)
  dir=$ROOT/$name
fi

mkdir "$tmp/x"
tar -xzf "$tmp/jank.tar.gz" -C "$tmp/x"
# The archive holds jank_0.1-1_aarch64/usr/local/{bin,lib,share}.
jank=$(find "$tmp/x" -path '*/usr/local/bin/jank' -type f | head -1)
if [ -z "$jank" ]; then
  echo "unexpected archive layout: no usr/local/bin/jank" >&2
  exit 1
fi
mkdir -p "$ROOT" "$BIN"
mv "$(dirname "$(dirname "$jank")")" "$dir"

cat > "$dir/SOURCE" <<EOF
url: $URL
last-modified: $modified
etag: $etag
sha256: $sha
installed: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

mkdir "$dir/shim"
cat > "$dir/shim/jank" <<EOF
#!/bin/sh
# jank $name with its own cache, and with lein-jank's compile folder target/... moved to
# target/jank-$name/... (lein-jank passes it as --build-dir and --target-dir).
XDG_CACHE_HOME=\$HOME/.cache/jank-$name
export XDG_CACHE_HOME
for a do
  shift
  case \$a in
    target) a=target/jank-$name ;;
    target/*) a=target/jank-$name/\${a#target/} ;;
  esac
  set -- "\$@" "\$a"
done
exec "$dir/bin/jank" "\$@"
EOF
chmod +x "$dir/shim/jank"

ln -sf "$dir/shim/jank" "$BIN/jank-$name"
cat > "$BIN/lein-jank-$name" <<EOF
#!/bin/sh
# lein with jank $name first on the PATH (lein-jank runs \`jank\` from the PATH).
PATH=$dir/shim:\$PATH
export PATH
exec lein "\$@"
EOF
chmod +x "$BIN/lein-jank-$name"

# The names of the newest one installed, for settings that shouldn't change with each build.
ln -sf "$BIN/jank-$name" "$BIN/jank-main"
ln -sf "$BIN/lein-jank-$name" "$BIN/lein-jank-main"

echo "installed jank $name (published $modified) in $dir"
echo "  run it:      jank-$name run file.jank"
echo "  with lein:   lein-jank-$name repl"
echo "  as \$JANK:    JANK=$BIN/jank-$name"
