#!/bin/bash
# Temporary diagnostic for the "LD_PRELOAD ... cannot be preloaded" failures
# observed in CI (see Dockerfile.probe): the library is freshly built and
# listed by ls, yet ld.so gets ENOENT for it - but only when it is loaded into
# gs, never into the benchmark binaries. This script prints the security
# context of the sandbox and of the processes themselves, and compares the
# file/preload behaviour of gs with that of other binaries. It changes nothing
# and always exits 0.

set +e
alloc=${1:-ff}
pdf=/mimalloc-bench/extern/large.pdf
lib=$(ls /mimalloc-bench/extern/$alloc/*.so 2>/dev/null | head -1)
libname=$(basename "$lib" 2>/dev/null)

echo "== PROBE($alloc): sandbox context =="
echo "  kernel:     $(uname -r)"
echo "  apparmor:   $(cat /sys/module/apparmor/parameters/enabled 2>&1)"
echo "  securityfs: $(ls /sys/kernel/security 2>&1 | head -1)"
echo "  self label: $(cat /proc/self/attr/current 2>&1)"
echo "  self exec:  $(cat /proc/self/attr/apparmor/exec 2>&1)"
echo "  init label: $(cat /proc/1/attr/current 2>&1)"
grep -E "^(Seccomp|NoNewPrivs|CapEff)" /proc/self/status | sed 's/^/  /'
echo "  dmesg_restrict: $(cat /proc/sys/kernel/dmesg_restrict 2>&1)"

echo "== PROBE: input and library integrity =="
ls -la "$pdf" "$lib" 2>&1 | sed 's/^/  /'
md5sum "$pdf" "$lib" 2>&1 | sed 's/^/  /'
echo "  first bytes of input: $(head -c 4 "$pdf" | od -An -c | tr -d ' \n')"
echo "  first bytes of lib:   $(head -c 4 "$lib" | od -An -c | tr -d ' \n')"

echo "== PROBE: non-gs processes on the same paths =="
echo "  head reads input: $(head -c 4 "$pdf" | od -An -c | tr -d ' \n')"
LD_PRELOAD="$lib" sh -c 'echo "  sh preload mappings: $(grep -c -a '"$libname"' /proc/self/maps)"' 2>&1 | sed 's/^/  /'
LD_PRELOAD="$lib" sh -c 'echo "  sh ran, rc-visible-to-caller"' 2>&1 | sed 's/^/  /'

echo "== PROBE: gs variants =="
echo "--- gs with $libname preloaded (what bench.sh does)"
LD_PRELOAD="$lib" gs -dBATCH -dNODISPLAY "$pdf" 2>&1 | tail -3
echo "--- gs without any preload"
gs -dBATCH -dNODISPLAY "$pdf" 2>&1 | tail -3
cp -f "$lib" /tmp/probe-lib.so 2>/dev/null
echo "--- gs with the same library copied to /tmp"
LD_PRELOAD=/tmp/probe-lib.so gs -dBATCH -dNODISPLAY "$pdf" 2>&1 | tail -3
cp -f "$(command -v gs)" /tmp/gscopy 2>/dev/null
echo "--- copy of gs at another path, same preload and input"
LD_PRELOAD="$lib" /tmp/gscopy -dBATCH -dNODISPLAY "$pdf" 2>&1 | tail -3
echo "--- preload only, no input file: library from the repo"
LD_PRELOAD="$lib" gs -dBATCH -dNOPAUSE -dNODISPLAY -q -c quit 2>&1 | tail -2
echo "    (no ld.so error above means the preload was accepted)"
echo "--- preload only, no input file: library copied to /tmp"
LD_PRELOAD=/tmp/probe-lib.so gs -dBATCH -dNOPAUSE -dNODISPLAY -q -c quit 2>&1 | tail -2
echo "--- input only: gs on a copy of the input in /tmp"
cp -f "$pdf" /tmp/probe.pdf 2>/dev/null
gs -dBATCH -dNODISPLAY /tmp/probe.pdf 2>&1 | tail -2

echo "== PROBE: label and preload state of live processes =="
LD_PRELOAD="$lib" sleep 20 &
shpid=$!
LD_PRELOAD="$lib" gs -dNOPAUSE -dBATCH -dNODISPLAY -sDEVICE=nullpage - < <(sleep 20) >/dev/null 2>&1 &
gspid=$!
sleep 1
echo "  sleep: label=$(cat /proc/$shpid/attr/current 2>&1) mappings-of-lib=$(grep -c -a "$libname" /proc/$shpid/maps 2>/dev/null)"
echo "  gs:    label=$(cat /proc/$gspid/attr/current 2>&1) mappings-of-lib=$(grep -c -a "$libname" /proc/$gspid/maps 2>/dev/null)"
kill $shpid $gspid 2>/dev/null
wait 2>/dev/null
( unset LD_PRELOAD; sleep 20 & p=$!; sleep 0.3
  echo "  sleep (no preload): label=$(cat /proc/$p/attr/current 2>&1)"; kill $p 2>/dev/null )

echo "== PROBE: strace of the failing gs run =="
if ! command -v strace >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq strace >/dev/null 2>&1
fi
if command -v strace >/dev/null 2>&1; then
  LD_PRELOAD="$lib" strace -f -e trace=openat,execve -o /tmp/gs.strace \
    gs -dBATCH -dNODISPLAY "$pdf" >/dev/null 2>&1
  echo "  denied opens (excluding unrelated gs/ld search paths):"
  grep -aE "ENOENT|EACCES" /tmp/gs.strace | grep -avE "ld\.cache|/lib/|/usr/lib/|locale|gs_|font|Resource|Font|Init" |
    head -8 | sed 's/^/    /'
  echo "  our two paths:"
  grep -aE "large\.pdf|$libname" /tmp/gs.strace | head -6 | sed 's/^/    /'
else
  echo "  strace unavailable"
fi
echo "== PROBE end =="
exit 0
