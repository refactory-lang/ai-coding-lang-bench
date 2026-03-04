#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
if [ ! -d node_modules/@types/node ]; then
  npm install --save-dev @types/node 2>/dev/null
fi
tsc --target es2020 --module commonjs --strict --esModuleInterop --skipLibCheck minigit.ts
echo '#!/usr/bin/env node' > minigit
cat minigit.js >> minigit
chmod +x minigit
