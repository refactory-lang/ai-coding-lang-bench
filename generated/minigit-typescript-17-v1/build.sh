#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
if [ ! -d node_modules ]; then
  npm install --silent 2>/dev/null
fi
npx tsc --strict --target ES2020 --module commonjs --outDir dist --skipLibCheck minigit.ts
cat > minigit <<'WRAPPER'
#!/usr/bin/env node
require('./dist/minigit.js');
WRAPPER
chmod +x minigit
