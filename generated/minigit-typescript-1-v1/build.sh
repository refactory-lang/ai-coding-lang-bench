#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
TSX_PATH=$(which tsx)
cat > minigit << EOF
#!/usr/bin/env bash
exec "$TSX_PATH" "\$(dirname "\$0")/minigit.ts" "\$@"
EOF
chmod +x minigit
