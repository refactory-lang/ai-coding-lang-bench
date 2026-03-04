minigit: minigit.ml
	ocamlfind ocamlopt -package unix -linkpkg -o minigit minigit.ml 2>/dev/null || \
	ocamlopt -I +unix unix.cmxa -o minigit minigit.ml 2>/dev/null || \
	ocamlc -I +unix unix.cma -o minigit minigit.ml

clean:
	rm -f minigit minigit.cmi minigit.cmo minigit.cmx minigit.o

.PHONY: clean
