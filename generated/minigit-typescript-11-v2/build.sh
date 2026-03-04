#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
npx tsc --project tsconfig.json
cat > minigit << 'SCRIPT'
#!/usr/bin/env node
require('./dist/minigit.js');
SCRIPT
chmod +x minigit
