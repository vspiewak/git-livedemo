#!/usr/bin/env sh
#
# Regenerate docs/demo.gif. Needs uv (https://docs.astral.sh/uv/) for Pillow.
#
set -eu
cd "$(dirname "$0")/../.."
exec uv run --quiet --with pillow python docs/demo/record.py
