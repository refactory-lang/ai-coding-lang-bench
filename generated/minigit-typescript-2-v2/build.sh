#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
tsc --target es2020 --module commonjs --strict minigit.ts
