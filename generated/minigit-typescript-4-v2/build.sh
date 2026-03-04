#!/bin/bash
cd "$(dirname "$0")"
tsc --target ES2020 --module commonjs --strict minigit.ts
cat > minigit << 'WRAPPER'
#!/bin/sh
exec node "$(dirname "$0")/minigit.js" "$@"
WRAPPER
chmod +x minigit
