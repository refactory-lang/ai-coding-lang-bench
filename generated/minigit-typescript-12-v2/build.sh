#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
npx -y esbuild minigit.ts --bundle --platform=node --outfile=minigit.js 2>/dev/null || \
  tsc --skipLibCheck --target es2020 --module commonjs --esModuleInterop --outDir . minigit.ts
cat > minigit <<'WRAPPER'
#!/usr/bin/env node
require("./minigit.js");
WRAPPER
chmod +x minigit
