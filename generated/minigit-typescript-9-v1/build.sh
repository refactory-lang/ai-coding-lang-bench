#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
tsc --target ES2020 --module commonjs --strict minigit.ts
echo '#!/usr/bin/env node' | cat - minigit.js > minigit
chmod +x minigit
