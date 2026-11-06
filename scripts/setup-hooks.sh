#!/bin/sh
# setup-hooks: turn on this repository's git hooks for this clone, from any folder inside it. The
# work is done by .githooks/bootstrap.sh; this is the name the README's quick start uses.
cd "$(dirname "$0")/.." || exit 1
exec bash .githooks/bootstrap.sh "$@"
