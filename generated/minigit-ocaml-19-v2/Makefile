minigit: minigit.ml
	ocamlfind ocamlopt -package unix -linkpkg -o minigit minigit.ml 2>/dev/null || \
	ocamlfind ocamlc -package unix -linkpkg -o minigit minigit.ml 2>/dev/null || \
	ocamlfind opt -package unix -linkpkg -o minigit minigit.ml 2>/dev/null || \
	ocamlfind c -package unix -linkpkg -o minigit minigit.ml 2>/dev/null || \
	ocamlfopt -o minigit unix.cmxa minigit.ml 2>/dev/null || \
	ocamlopt -o minigit unix.cmxa minigit.ml

clean:
	rm -f minigit *.cmi *.cmx *.cmo *.o

.PHONY: clean
