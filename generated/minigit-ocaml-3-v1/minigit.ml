let minigit_dir = ".minigit"
let objects_dir = ".minigit/objects"
let commits_dir = ".minigit/commits"
let index_file = ".minigit/index"
let head_file = ".minigit/HEAD"

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let minihash data =
  let h = ref 1469598103934665603L in
  String.iter (fun c ->
    let b = Int64.of_int (Char.code c) in
    h := Int64.logxor !h b;
    h := Int64.mul !h 1099511628211L
  ) data;
  Printf.sprintf "%016Lx" !h

let read_index () =
  if not (Sys.file_exists index_file) then []
  else
    let content = read_file index_file in
    if String.length content = 0 then []
    else
      String.split_on_char '\n' content
      |> List.filter (fun s -> String.length s > 0)

let cmd_init () =
  if Sys.file_exists minigit_dir && Sys.is_directory minigit_dir then
    print_endline "Repository already initialized"
  else begin
    Unix.mkdir minigit_dir 0o755;
    Unix.mkdir objects_dir 0o755;
    Unix.mkdir commits_dir 0o755;
    write_file index_file "";
    write_file head_file ""
  end

let cmd_add filename =
  if not (Sys.file_exists filename) then begin
    print_endline "File not found";
    exit 1
  end;
  let content = read_file filename in
  let hash = minihash content in
  write_file (objects_dir ^ "/" ^ hash) content;
  let index_lines = read_index () in
  if not (List.mem filename index_lines) then begin
    let oc = open_out_gen [Open_append; Open_creat; Open_binary] 0o644 index_file in
    output_string oc (filename ^ "\n");
    close_out oc
  end

let cmd_commit message =
  let index_lines = read_index () in
  if index_lines = [] then begin
    print_endline "Nothing to commit";
    exit 1
  end;
  let parent =
    let head = String.trim (read_file head_file) in
    if String.length head = 0 then "NONE" else head
  in
  let timestamp = int_of_float (Unix.time ()) in
  let sorted_files = List.sort String.compare index_lines in
  let file_entries = List.map (fun f ->
    let content = read_file f in
    let hash = minihash content in
    f ^ " " ^ hash
  ) sorted_files in
  let commit_content = Printf.sprintf "parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n"
    parent timestamp message (String.concat "\n" file_entries) in
  let commit_hash = minihash commit_content in
  write_file (commits_dir ^ "/" ^ commit_hash) commit_content;
  write_file head_file commit_hash;
  write_file index_file "";
  Printf.printf "Committed %s\n" commit_hash

let parse_commit_field lines prefix =
  let plen = String.length prefix in
  let line = List.find (fun l ->
    String.length l >= plen && String.sub l 0 plen = prefix
  ) lines in
  String.sub line plen (String.length line - plen)

let cmd_log () =
  let head = String.trim (read_file head_file) in
  if String.length head = 0 then
    print_endline "No commits"
  else begin
    let rec traverse hash first =
      if hash = "NONE" || String.length hash = 0 then ()
      else begin
        let content = read_file (commits_dir ^ "/" ^ hash) in
        let lines = String.split_on_char '\n' content in
        let parent = parse_commit_field lines "parent: " in
        let timestamp = parse_commit_field lines "timestamp: " in
        let message = parse_commit_field lines "message: " in
        if not first then print_newline ();
        Printf.printf "commit %s\nDate: %s\nMessage: %s\n" hash timestamp message;
        traverse parent false
      end
    in
    traverse head true
  end

let () =
  let args = Sys.argv in
  let argc = Array.length args in
  if argc < 2 then begin
    Printf.eprintf "Usage: minigit <command>\n";
    exit 1
  end;
  match args.(1) with
  | "init" -> cmd_init ()
  | "add" ->
    if argc < 3 then begin
      Printf.eprintf "Usage: minigit add <file>\n";
      exit 1
    end;
    cmd_add args.(2)
  | "commit" ->
    if argc < 4 || args.(2) <> "-m" then begin
      Printf.eprintf "Usage: minigit commit -m <message>\n";
      exit 1
    end;
    cmd_commit args.(3)
  | "log" -> cmd_log ()
  | cmd ->
    Printf.eprintf "Unknown command: %s\n" cmd;
    exit 1
