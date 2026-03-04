all: minigit

minigit: MiniGit.hs
	ghc -O2 -o minigit MiniGit.hs 2>/dev/null

clean:
	rm -f minigit *.o *.hi

.PHONY: all clean
