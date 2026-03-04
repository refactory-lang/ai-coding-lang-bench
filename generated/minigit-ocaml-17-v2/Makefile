minigit: minigit.ml
	ocamlfind ocamlopt -package unix -linkpkg -o minigit minigit.ml 2>/dev/null || \
	ocamlopt -o minigit unix.cmxa minigit.ml 2>/dev/null || \
	ocamlc -o minigit unix.cma minigit.ml

clean:
	rm -f minigit *.cmi *.cmx *.cmo *.o

.PHONY: clean
