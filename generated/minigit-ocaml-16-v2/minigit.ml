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

let read_index () =
  let content = read_file ".minigit/index" in
  if String.trim content = "" then []
  else
    String.split_on_char '\n' content
    |> List.filter (fun s -> s <> "")

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
    let oc = open_out ".minigit/index" in
    close_out oc;
    let oc = open_out ".minigit/HEAD" in
    close_out oc
  end

let cmd_add file =
  if not (Sys.file_exists file) then begin
    print_endline "File not found";
    exit 1
  end;
  let content = read_file file in
  let hash = minihash content in
  write_file (".minigit/objects/" ^ hash) content;
  let index = read_index () in
  if not (List.mem file index) then begin
    let oc = open_out_gen [Open_append; Open_creat] 0o644 ".minigit/index" in
    output_string oc (file ^ "\n");
    close_out oc
  end

let cmd_commit msg =
  let index = read_index () in
  if index = [] then begin
    print_endline "Nothing to commit";
    exit 1
  end;
  let parent =
    let s = String.trim (read_file ".minigit/HEAD") in
    if s = "" then "NONE" else s
  in
  let timestamp = int_of_float (Unix.time ()) in
  let sorted_files = List.sort String.compare index in
  let file_lines = List.map (fun f ->
    let content = read_file f in
    let hash = minihash content in
    f ^ " " ^ hash
  ) sorted_files in
  let commit_content = Printf.sprintf "parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n"
    parent timestamp msg (String.concat "\n" file_lines) in
  let commit_hash = minihash commit_content in
  write_file (".minigit/commits/" ^ commit_hash) commit_content;
  write_file ".minigit/HEAD" commit_hash;
  write_file ".minigit/index" "";
  Printf.printf "Committed %s\n" commit_hash

let rec log_traverse hash =
  let path = ".minigit/commits/" ^ hash in
  let content = read_file path in
  let lines = String.split_on_char '\n' content in
  let parent = ref "NONE" in
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
  Printf.printf "commit %s\nDate: %s\nMessage: %s\n\n" hash !timestamp !message;
  if !parent <> "NONE" then
    log_traverse !parent

let cmd_log () =
  let head = String.trim (read_file ".minigit/HEAD") in
  if head = "" then
    print_endline "No commits"
  else
    log_traverse head

let cmd_status () =
  let index = read_index () in
  print_endline "Staged files:";
  if index = [] then
    print_endline "(none)"
  else
    List.iter print_endline index

let parse_commit content =
  let lines = String.split_on_char '\n' content in
  let parent = ref "NONE" in
  let timestamp = ref "" in
  let message = ref "" in
  let files = ref [] in
  let in_files = ref false in
  List.iter (fun line ->
    let len = String.length line in
    if !in_files then begin
      if line <> "" then begin
        let space_idx = String.index line ' ' in
        let fname = String.sub line 0 space_idx in
        let hash = String.sub line (space_idx + 1) (len - space_idx - 1) in
        files := (fname, hash) :: !files
      end
    end else if len > 8 && String.sub line 0 8 = "parent: " then
      parent := String.sub line 8 (len - 8)
    else if len > 11 && String.sub line 0 11 = "timestamp: " then
      timestamp := String.sub line 11 (len - 11)
    else if len > 9 && String.sub line 0 9 = "message: " then
      message := String.sub line 9 (len - 9)
    else if line = "files:" then
      in_files := true
  ) lines;
  (!parent, !timestamp, !message, List.rev !files)

let cmd_diff hash1 hash2 =
  let path1 = ".minigit/commits/" ^ hash1 in
  let path2 = ".minigit/commits/" ^ hash2 in
  if not (Sys.file_exists path1) || not (Sys.file_exists path2) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let (_, _, _, files1) = parse_commit (read_file path1) in
  let (_, _, _, files2) = parse_commit (read_file path2) in
  let all_files = List.sort_uniq String.compare
    (List.map fst files1 @ List.map fst files2) in
  List.iter (fun fname ->
    let h1 = List.assoc_opt fname files1 in
    let h2 = List.assoc_opt fname files2 in
    match h1, h2 with
    | None, Some _ -> Printf.printf "Added: %s\n" fname
    | Some _, None -> Printf.printf "Removed: %s\n" fname
    | Some a, Some b -> if a <> b then Printf.printf "Modified: %s\n" fname
    | None, None -> ()
  ) all_files

let cmd_checkout hash =
  let path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let (_, _, _, files) = parse_commit (read_file path) in
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
  let index = read_index () in
  if not (List.mem file index) then begin
    print_endline "File not in index";
    exit 1
  end;
  let new_index = List.filter (fun f -> f <> file) index in
  let content = if new_index = [] then ""
    else String.concat "\n" new_index ^ "\n" in
  write_file ".minigit/index" content

let cmd_show hash =
  let path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let (_, timestamp, message, files) = parse_commit (read_file path) in
  Printf.printf "commit %s\n" hash;
  Printf.printf "Date: %s\n" timestamp;
  Printf.printf "Message: %s\n" message;
  print_endline "Files:";
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) files in
  List.iter (fun (fname, blob_hash) ->
    Printf.printf "  %s %s\n" fname blob_hash
  ) sorted

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
