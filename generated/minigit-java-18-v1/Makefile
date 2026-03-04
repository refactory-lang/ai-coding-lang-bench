all:
	javac MiniGit.java
	echo '#!/bin/sh' > minigit
	echo 'DIR=$$(cd "$$(dirname "$$0")" && pwd)' >> minigit
	echo 'java -cp "$$DIR" MiniGit "$$@"' >> minigit
	chmod +x minigit
