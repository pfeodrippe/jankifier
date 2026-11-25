#!/bin/bash
# Tests the Elle oracle: starts it on a fresh temp dir, sends the closed-predicate histories of
# determinismo-workloads' results (closed-predicate.cases.edn and -2) and a few other requests,
# compares the answers with .elle.edn, then stops it. Prints PASS/FAIL lines and a summary.
here=$(cd "$(dirname "$0")" && pwd)
dir=$(mktemp -d "${TMPDIR:-/tmp}/elle-oracle-test.XXXXXX") || exit 1
log="$dir.log"
out="$dir.out"
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

t0=$(ms)
"$here/oracle.sh" "$dir" > "$log" 2>&1 &
pid=$!
trap 'kill -0 $pid 2>/dev/null && kill $pid' EXIT

# Wait for the oracle to load Elle (DIR/ready).
while [ ! -e "$dir/ready" ]; do
  if ! kill -0 $pid 2>/dev/null; then echo "FAIL the oracle exited while starting:"; cat "$log"; exit 1; fi
  if [ $(( $(ms) - t0 )) -gt 120000 ]; then echo "FAIL the oracle was not ready in 120 s"; exit 1; fi
  sleep 0.05
done
echo "oracle ready $(( $(ms) - t0 )) ms after start ($(grep -o 'after [0-9]* ms of JVM time' "$log"))"

java -cp "$("$here/classpath.sh")" clojure.main "$here/test.clj" "$dir" 2>&1 | tee "$out"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ] && ! grep -q '^FAIL' "$out"; then
  echo "FAIL test.clj - exited with status $status" | tee -a "$out"
fi

# Stop: the oracle exits and deletes DIR/stop and DIR/ready.
t1=$(ms)
touch "$dir/stop"
while kill -0 $pid 2>/dev/null && [ $(( $(ms) - t1 )) -lt 10000 ]; do sleep 0.05; done
if kill -0 $pid 2>/dev/null; then
  echo "FAIL stop - the oracle still runs 10 s after DIR/stop" | tee -a "$out"
elif [ -e "$dir/stop" ] || [ -e "$dir/ready" ]; then
  echo "FAIL stop - the oracle exited but left DIR/stop or DIR/ready" | tee -a "$out"
else
  echo "PASS stop - exited $(( $(ms) - t1 )) ms after DIR/stop" | tee -a "$out"
fi

echo
echo "oracle's time per request (from its log):"
grep -E '\.req\.edn [0-9.]+ ms' "$log" | awk '{print "  " $2, $3, $4}'
pass=$(grep -c '^PASS' "$out")
fail=$(grep -c '^FAIL' "$out")
echo
echo "summary: $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
  rm -rf "$dir" "$log" "$out"
  exit 0
else
  echo "kept for inspection: $dir $log"
  exit 1
fi
