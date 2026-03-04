#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
npx -y tsc --target es2020 --module commonjs --outDir "$DIR" --strict false "$DIR/minigit.ts" 2>/dev/null || {
  # Fallback: strip type annotations manually if tsc fails
  sed -E 's/: Buffer//g; s/: string//g; s/: void//g; s/: number//g; s/: boolean//g; s/: any//g; s/ as any\[\]//g; s/ as any//g' "$DIR/minigit.ts" > "$DIR/minigit.js"
}
chmod +x "$DIR/minigit"
