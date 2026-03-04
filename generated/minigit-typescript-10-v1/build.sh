#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
npx -y tsc --target es2020 --module commonjs --outDir "$DIR" --strict false "$DIR/minigit.ts" 2>/dev/null || {
  # Fallback: strip type annotations manually if tsc fails
  sed 's/: Buffer//g; s/: string//g; s/: void//g' "$DIR/minigit.ts" > "$DIR/minigit.js"
}
chmod +x "$DIR/minigit"
