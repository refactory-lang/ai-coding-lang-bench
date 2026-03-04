#!/usr/bin/env bash
cd "$(dirname "$0")"
npx tsc --esModuleInterop --module commonjs --target es2020 minigit.ts
echo '#!/usr/bin/env node' | cat - minigit.js > minigit.tmp && mv minigit.tmp minigit
chmod +x minigit
