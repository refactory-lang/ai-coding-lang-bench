all: minigit

minigit: MiniGit.java
	javac MiniGit.java
	echo '#!/bin/bash' > minigit
	echo 'DIR="$$(cd "$$(dirname "$$0")" && pwd)"' >> minigit
	echo 'java -cp "$$DIR" MiniGit "$$@"' >> minigit
	chmod +x minigit

clean:
	rm -f *.class minigit
