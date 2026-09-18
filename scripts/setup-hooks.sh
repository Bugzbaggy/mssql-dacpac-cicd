#!/bin/sh
# Point this clone at the versioned hooks in .githooks/.
# Run once after cloning:  ./scripts/setup-hooks.sh
set -e
git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true
echo "core.hooksPath set to .githooks"
