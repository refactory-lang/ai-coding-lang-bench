#!/usr/bin/env bash
cd "$(dirname "$0")"
npx tsc --strict --target ES2020 --module commonjs --moduleResolution node --types node --skipLibCheck minigit.ts 2>/dev/null || npx -p typescript tsc --strict --target ES2020 --module commonjs --moduleResolution node --types node --skipLibCheck minigit.ts
cat > minigit <<'WRAPPER'
#!/usr/bin/env node
require('./minigit.js');
WRAPPER
chmod +x minigit
