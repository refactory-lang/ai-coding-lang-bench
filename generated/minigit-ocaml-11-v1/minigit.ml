let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.to_string buf

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

let cmd_init () =
  if Sys.file_exists ".minigit" then (
    print_string "Repository already initialized\n";
    exit 0
  );
  Unix.mkdir ".minigit" 0o755;
  Unix.mkdir ".minigit/objects" 0o755;
  Unix.mkdir ".minigit/commits" 0o755;
  let oc = open_out ".minigit/index" in
  close_out oc;
  let oc = open_out ".minigit/HEAD" in
  close_out oc

let cmd_add file =
  if not (Sys.file_exists file) then (
    print_string "File not found\n";
    exit 1
  );
  let content = read_file file in
  let hash = minihash content in
  write_file (".minigit/objects/" ^ hash) content;
  let index_content = read_file ".minigit/index" in
  let lines = String.split_on_char '\n' index_content
    |> List.filter (fun s -> s <> "") in
  if not (List.mem file lines) then (
    let oc = open_out_gen [Open_append; Open_wronly] 0o644 ".minigit/index" in
    output_string oc (file ^ "\n");
    close_out oc
  )

let cmd_commit msg =
  let index_content = read_file ".minigit/index" in
  let files = String.split_on_char '\n' index_content
    |> List.filter (fun s -> s <> "") in
  if files = [] then (
    print_string "Nothing to commit\n";
    exit 1
  );
  let head_content = String.trim (read_file ".minigit/HEAD") in
  let parent = if head_content = "" then "NONE" else head_content in
  let timestamp = int_of_float (Unix.time ()) in
  let sorted_files = List.sort String.compare files in
  let file_entries = List.map (fun f ->
    let content = read_file f in
    let hash = minihash content in
    Printf.sprintf "%s %s" f hash
  ) sorted_files in
  let commit_content = Printf.sprintf "parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n"
    parent timestamp msg (String.concat "\n" file_entries) in
  let commit_hash = minihash commit_content in
  write_file (".minigit/commits/" ^ commit_hash) commit_content;
  write_file ".minigit/HEAD" commit_hash;
  write_file ".minigit/index" "";
  Printf.printf "Committed %s\n" commit_hash

let cmd_log () =
  let head_content = String.trim (read_file ".minigit/HEAD") in
  if head_content = "" then (
    print_string "No commits\n";
    exit 0
  );
  let rec walk hash =
    let commit_content = read_file (".minigit/commits/" ^ hash) in
    let lines = String.split_on_char '\n' commit_content in
    let get_field prefix =
      let line = List.find (fun l ->
        let plen = String.length prefix in
        String.length l >= plen && String.sub l 0 plen = prefix
      ) lines in
      String.sub line (String.length prefix) (String.length line - String.length prefix)
    in
    let parent = get_field "parent: " in
    let timestamp = get_field "timestamp: " in
    let message = get_field "message: " in
    Printf.printf "commit %s\nDate: %s\nMessage: %s\n\n" hash timestamp message;
    if parent <> "NONE" then
      walk parent
  in
  walk head_content

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  match args with
  | ["init"] -> cmd_init ()
  | ["add"; file] -> cmd_add file
  | ["commit"; "-m"; msg] -> cmd_commit msg
  | ["log"] -> cmd_log ()
  | _ ->
    Printf.eprintf "Unknown command\n";
    exit 1
