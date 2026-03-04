minigit: minigit.ml
	ocamlfind ocamlopt -package unix -linkpkg -o minigit minigit.ml 2>/dev/null || \
	ocamlfind ocamlc -package unix -linkpkg -o minigit minigit.ml 2>/dev/null || \
	ocamlopt -I +unix unix.cmxa -o minigit minigit.ml 2>/dev/null || \
	ocamlc -I +unix unix.cma -o minigit minigit.ml

clean:
	rm -f minigit *.cmi *.cmx *.cmo *.o

.PHONY: clean
