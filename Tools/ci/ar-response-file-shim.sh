#!/usr/bin/env bash
# Archiver wrapper that spills the object list into an @response file.
#
# SCons on POSIX builds ARCOM as "$AR $ARFLAGS $TARGET $SOURCES" and runs it
# through sh, so every object path lands in a single argv entry - capped at
# 128 KB by the kernel (MAX_ARG_STRLEN). godot-cpp is 1022 translation units:
# ~96 KB of relative paths, but ~131 KB once SCons switches to absolute paths,
# which it does for every extension that reaches godot-cpp from outside its own
# top directory. The result is "sh: Argument list too long" from ar, and it is
# already only 27% under the limit for the relative case.
#
# llvm-ar and GNU ar both accept @file, so the fix is to stop passing them on
# the command line at all. The real archiver is expected at "$0.real".
set -u

real="$0.real"
[ -x "$real" ] || { echo "ar shim: no real archiver at $real" >&2; exit 127; }

# Short invocations (and anything that is not the operation+archive+members
# form) go straight through, so this cannot change ar's behaviour where the
# limit was never in play.
if [ "$#" -le 2 ]; then
    exec "$real" "$@"
fi

op=$1
archive=$2
shift 2

rsp=$(mktemp)
printf '%s\n' "$@" > "$rsp"
"$real" "$op" "$archive" "@$rsp"
rc=$?
rm -f "$rsp"
exit "$rc"
