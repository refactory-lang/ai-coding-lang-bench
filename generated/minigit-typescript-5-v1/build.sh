#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
tsc --target ES2020 --module commonjs --strict minigit.ts
cat > minigit <<'WRAPPER'
#!/usr/bin/env node
require('./minigit.js');
WRAPPER
chmod +x minigit
