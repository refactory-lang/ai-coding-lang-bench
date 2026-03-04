#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
tsc --project tsconfig.json
cat > minigit <<'WRAPPER'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$DIR/dist/minigit.js" "$@"
WRAPPER
chmod +x minigit
