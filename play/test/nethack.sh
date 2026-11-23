#!/usr/bin/env bash
# NetHack (the NetHack Learning Environment's build in vendor/) played by its own example
# program: three games of random moves, each to its end. A directory of its own for the
# game's files (target/nethack-run), and a player's name that isn't the user's.
set -euo pipefail
cd "$(dirname "$0")/.."
here=$PWD
run=target/nethack-run
rm -rf $run && mkdir -p $run/save
ln -s $here/vendor/nle/build/dat/nhdat $run/nhdat
for f in perm record logfile xlogfile; do touch $run/$f; done
cp vendor/nle/build/libnethack.so $run/
cd $run
export HACKDIR=$PWD/ USER=agent
export NETHACKOPTIONS='autopickup,color,disclose:+i +a +v +g +c +o,mention_walls,nobones,nocmdassist,nolegacy,nosparkle,pickup_burden:unencumbered,pickup_types:$?!/,runmode:teleport,showexp,showscore,time'
$here/vendor/nle/build/rlmain r < /dev/null > rl.out 2>&1
echo "games played: $(wc -l < xlogfile)"
cut -f5,11-13,17,19 xlogfile | tr '\t' ' '
