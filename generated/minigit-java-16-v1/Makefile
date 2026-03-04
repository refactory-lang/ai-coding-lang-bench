all: minigit

minigit: MiniGit.java
	javac MiniGit.java
	@echo '#!/bin/bash' > minigit
	@echo 'exec java -cp "$$(dirname "$$0")" MiniGit "$$@"' >> minigit
	chmod +x minigit

clean:
	rm -f *.class minigit

.PHONY: all clean
