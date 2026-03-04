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

let parse_commit_fields commit_content =
  let lines = String.split_on_char '\n' commit_content in
  let get_field prefix =
    let line = List.find (fun l ->
      let plen = String.length prefix in
      String.length l >= plen && String.sub l 0 plen = prefix
    ) lines in
    String.sub line (String.length prefix) (String.length line - String.length prefix)
  in
  (get_field "parent: ", get_field "timestamp: ", get_field "message: ")

let parse_commit_files commit_content =
  let lines = String.split_on_char '\n' commit_content in
  let rec skip_to_files = function
    | [] -> []
    | l :: rest ->
      if l = "files:" then rest
      else skip_to_files rest
  in
  let file_lines = skip_to_files lines in
  List.filter_map (fun l ->
    if l = "" then None
    else
      match String.split_on_char ' ' l with
      | [name; hash] -> Some (name, hash)
      | _ -> None
  ) file_lines

let cmd_status () =
  let index_content = read_file ".minigit/index" in
  let files = String.split_on_char '\n' index_content
    |> List.filter (fun s -> s <> "") in
  print_string "Staged files:\n";
  if files = [] then
    print_string "(none)\n"
  else
    List.iter (fun f -> Printf.printf "%s\n" f) files

let cmd_log () =
  let head_content = String.trim (read_file ".minigit/HEAD") in
  if head_content = "" then (
    print_string "No commits\n";
    exit 0
  );
  let rec walk hash =
    let commit_content = read_file (".minigit/commits/" ^ hash) in
    let (parent, timestamp, message) = parse_commit_fields commit_content in
    Printf.printf "commit %s\nDate: %s\nMessage: %s\n\n" hash timestamp message;
    if parent <> "NONE" then
      walk parent
  in
  walk head_content

let cmd_diff c1 c2 =
  let check_commit h =
    let path = ".minigit/commits/" ^ h in
    if not (Sys.file_exists path) then (
      print_string "Invalid commit\n";
      exit 1
    )
  in
  check_commit c1;
  check_commit c2;
  let files1 = parse_commit_files (read_file (".minigit/commits/" ^ c1)) in
  let files2 = parse_commit_files (read_file (".minigit/commits/" ^ c2)) in
  let all_names =
    let names = List.map fst files1 @ List.map fst files2 in
    List.sort_uniq String.compare names
  in
  List.iter (fun name ->
    let in1 = List.assoc_opt name files1 in
    let in2 = List.assoc_opt name files2 in
    match in1, in2 with
    | None, Some _ -> Printf.printf "Added: %s\n" name
    | Some _, None -> Printf.printf "Removed: %s\n" name
    | Some h1, Some h2 -> if h1 <> h2 then Printf.printf "Modified: %s\n" name
    | None, None -> ()
  ) all_names

let cmd_checkout hash =
  let commit_path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists commit_path) then (
    print_string "Invalid commit\n";
    exit 1
  );
  let commit_content = read_file commit_path in
  let files = parse_commit_files commit_content in
  List.iter (fun (name, blob_hash) ->
    let blob_content = read_file (".minigit/objects/" ^ blob_hash) in
    write_file name blob_content
  ) files;
  write_file ".minigit/HEAD" hash;
  write_file ".minigit/index" "";
  Printf.printf "Checked out %s\n" hash

let cmd_reset hash =
  let commit_path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists commit_path) then (
    print_string "Invalid commit\n";
    exit 1
  );
  write_file ".minigit/HEAD" hash;
  write_file ".minigit/index" "";
  Printf.printf "Reset to %s\n" hash

let cmd_rm file =
  let index_content = read_file ".minigit/index" in
  let lines = String.split_on_char '\n' index_content
    |> List.filter (fun s -> s <> "") in
  if not (List.mem file lines) then (
    print_string "File not in index\n";
    exit 1
  );
  let new_lines = List.filter (fun s -> s <> file) lines in
  let new_content = if new_lines = [] then "" else String.concat "\n" new_lines ^ "\n" in
  write_file ".minigit/index" new_content

let cmd_show hash =
  let commit_path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists commit_path) then (
    print_string "Invalid commit\n";
    exit 1
  );
  let commit_content = read_file commit_path in
  let (_, timestamp, message) = parse_commit_fields commit_content in
  let files = parse_commit_files commit_content in
  Printf.printf "commit %s\nDate: %s\nMessage: %s\nFiles:\n" hash timestamp message;
  List.iter (fun (name, blob_hash) ->
    Printf.printf "  %s %s\n" name blob_hash
  ) (List.sort (fun (a, _) (b, _) -> String.compare a b) files)

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  match args with
  | ["init"] -> cmd_init ()
  | ["add"; file] -> cmd_add file
  | ["commit"; "-m"; msg] -> cmd_commit msg
  | ["status"] -> cmd_status ()
  | ["log"] -> cmd_log ()
  | ["diff"; c1; c2] -> cmd_diff c1 c2
  | ["checkout"; hash] -> cmd_checkout hash
  | ["reset"; hash] -> cmd_reset hash
  | ["rm"; file] -> cmd_rm file
  | ["show"; hash] -> cmd_show hash
  | _ ->
    Printf.eprintf "Unknown command\n";
    exit 1
