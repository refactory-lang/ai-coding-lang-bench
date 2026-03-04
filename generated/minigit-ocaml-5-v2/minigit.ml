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

let cmd_init () =
  if Sys.file_exists ".minigit" then
    print_endline "Repository already initialized"
  else begin
    Unix.mkdir ".minigit" 0o755;
    Unix.mkdir ".minigit/objects" 0o755;
    Unix.mkdir ".minigit/commits" 0o755;
    let oc = open_out ".minigit/index" in close_out oc;
    let oc = open_out ".minigit/HEAD" in close_out oc
  end

let cmd_add file =
  if not (Sys.file_exists file) then begin
    print_endline "File not found";
    exit 1
  end;
  let content = read_file file in
  let hash = minihash content in
  write_file (".minigit/objects/" ^ hash) content;
  let index_content = read_file ".minigit/index" in
  let entries =
    if index_content = "" then []
    else String.split_on_char '\n' index_content
         |> List.filter (fun s -> s <> "")
  in
  if not (List.mem file entries) then
    let new_entries = entries @ [file] in
    write_file ".minigit/index" (String.concat "\n" new_entries ^ "\n")

let cmd_commit msg =
  let index_content = read_file ".minigit/index" in
  let entries =
    if index_content = "" then []
    else String.split_on_char '\n' index_content
         |> List.filter (fun s -> s <> "")
  in
  if entries = [] then begin
    print_endline "Nothing to commit";
    exit 1
  end;
  let sorted = List.sort String.compare entries in
  let head_content = String.trim (read_file ".minigit/HEAD") in
  let parent = if head_content = "" then "NONE" else head_content in
  let timestamp = int_of_float (Unix.time ()) in
  let file_lines = List.map (fun fname ->
    let content = read_file fname in
    let hash = minihash content in
    Printf.sprintf "%s %s" fname hash
  ) sorted in
  let commit_content = Printf.sprintf "parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n"
    parent timestamp msg (String.concat "\n" file_lines) in
  let commit_hash = minihash commit_content in
  write_file (".minigit/commits/" ^ commit_hash) commit_content;
  write_file ".minigit/HEAD" commit_hash;
  write_file ".minigit/index" "";
  Printf.printf "Committed %s\n" commit_hash

let cmd_status () =
  let index_content = read_file ".minigit/index" in
  let entries =
    if index_content = "" then []
    else String.split_on_char '\n' index_content
         |> List.filter (fun s -> s <> "")
  in
  print_endline "Staged files:";
  if entries = [] then
    print_endline "(none)"
  else
    List.iter print_endline entries

let parse_commit_files commit_content =
  let lines = String.split_on_char '\n' commit_content in
  let in_files = ref false in
  let files = ref [] in
  List.iter (fun line ->
    if line = "files:" then
      in_files := true
    else if !in_files && line <> "" then begin
      match String.split_on_char ' ' line with
      | [fname; hash] -> files := (fname, hash) :: !files
      | _ -> ()
    end
  ) lines;
  List.rev !files

let parse_commit commit_content =
  let lines = String.split_on_char '\n' commit_content in
  let parent = ref "" in
  let timestamp = ref "" in
  let message = ref "" in
  List.iter (fun line ->
    let len = String.length line in
    if len > 8 && String.sub line 0 8 = "parent: " then
      parent := String.sub line 8 (len - 8)
    else if len > 11 && String.sub line 0 11 = "timestamp: " then
      timestamp := String.sub line 11 (len - 11)
    else if len > 9 && String.sub line 0 9 = "message: " then
      message := String.sub line 9 (len - 9)
  ) lines;
  (!parent, !timestamp, !message)

let cmd_log () =
  let head_content = String.trim (read_file ".minigit/HEAD") in
  if head_content = "" then
    print_endline "No commits"
  else
    let rec walk hash =
      let commit_content = read_file (".minigit/commits/" ^ hash) in
      let (parent, timestamp, message) = parse_commit commit_content in
      Printf.printf "commit %s\nDate: %s\nMessage: %s\n\n" hash timestamp message;
      if parent <> "NONE" then
        walk parent
    in
    walk head_content

let cmd_diff hash1 hash2 =
  let path1 = ".minigit/commits/" ^ hash1 in
  let path2 = ".minigit/commits/" ^ hash2 in
  if not (Sys.file_exists path1) || not (Sys.file_exists path2) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let files1 = parse_commit_files (read_file path1) in
  let files2 = parse_commit_files (read_file path2) in
  let all_names =
    let names = List.map fst files1 @ List.map fst files2 in
    List.sort_uniq String.compare names
  in
  List.iter (fun name ->
    let h1 = List.assoc_opt name files1 in
    let h2 = List.assoc_opt name files2 in
    match h1, h2 with
    | None, Some _ -> Printf.printf "Added: %s\n" name
    | Some _, None -> Printf.printf "Removed: %s\n" name
    | Some a, Some b when a <> b -> Printf.printf "Modified: %s\n" name
    | _ -> ()
  ) all_names

let cmd_checkout hash =
  let path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let commit_content = read_file path in
  let files = parse_commit_files commit_content in
  List.iter (fun (fname, blob_hash) ->
    let blob_content = read_file (".minigit/objects/" ^ blob_hash) in
    write_file fname blob_content
  ) files;
  write_file ".minigit/HEAD" hash;
  write_file ".minigit/index" "";
  Printf.printf "Checked out %s\n" hash

let cmd_reset hash =
  let path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  write_file ".minigit/HEAD" hash;
  write_file ".minigit/index" "";
  Printf.printf "Reset to %s\n" hash

let cmd_rm file =
  let index_content = read_file ".minigit/index" in
  let entries =
    if index_content = "" then []
    else String.split_on_char '\n' index_content
         |> List.filter (fun s -> s <> "")
  in
  if not (List.mem file entries) then begin
    print_endline "File not in index";
    exit 1
  end;
  let new_entries = List.filter (fun s -> s <> file) entries in
  if new_entries = [] then
    write_file ".minigit/index" ""
  else
    write_file ".minigit/index" (String.concat "\n" new_entries ^ "\n")

let cmd_show hash =
  let path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let commit_content = read_file path in
  let (_, timestamp, message) = parse_commit commit_content in
  let files = parse_commit_files commit_content in
  Printf.printf "commit %s\n" hash;
  Printf.printf "Date: %s\n" timestamp;
  Printf.printf "Message: %s\n" message;
  print_endline "Files:";
  List.iter (fun (fname, blob_hash) ->
    Printf.printf "  %s %s\n" fname blob_hash
  ) (List.sort (fun (a, _) (b, _) -> String.compare a b) files)

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  match args with
  | ["init"] -> cmd_init ()
  | ["add"; file] -> cmd_add file
  | ["commit"; "-m"; msg] -> cmd_commit msg
  | ["status"] -> cmd_status ()
  | ["log"] -> cmd_log ()
  | ["diff"; h1; h2] -> cmd_diff h1 h2
  | ["checkout"; hash] -> cmd_checkout hash
  | ["reset"; hash] -> cmd_reset hash
  | ["rm"; file] -> cmd_rm file
  | ["show"; hash] -> cmd_show hash
  | _ ->
    Printf.eprintf "Unknown command\n";
    exit 1
