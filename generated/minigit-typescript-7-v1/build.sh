#!/usr/bin/env bash
cd "$(dirname "$0")"
npx tsc --strict --target ES2020 --module commonjs --esModuleInterop minigit.ts 2>/dev/null
