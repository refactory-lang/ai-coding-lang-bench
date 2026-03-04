#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
npx tsc
cat > minigit << 'WRAPPER'
#!/usr/bin/env node
require('./dist/minigit.js');
WRAPPER
chmod +x minigit
