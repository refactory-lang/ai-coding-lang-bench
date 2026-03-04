#!/usr/bin/env bash
cd "$(dirname "$0")"
if [ ! -d node_modules/@types/node ]; then
  npm install --save-dev @types/node 2>/dev/null
fi
tsc --target es2020 --module commonjs --strict --skipLibCheck --outDir . minigit.ts
