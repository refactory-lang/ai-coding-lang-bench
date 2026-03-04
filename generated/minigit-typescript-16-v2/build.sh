#!/usr/bin/env bash
cd "$(dirname "$0")"
npm install --save-dev @types/node typescript 2>/dev/null >/dev/null
npx tsc --esModuleInterop --module commonjs --target es2020 --skipLibCheck minigit.ts 2>/dev/null
cat > minigit << 'WRAPPER'
#!/usr/bin/env node
require('./minigit.js');
WRAPPER
chmod +x minigit
