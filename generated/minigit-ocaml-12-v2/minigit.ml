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
  let content = String.trim (read_file ".minigit/index") in
  if content = "" then []
  else
    String.split_on_char '\n' content
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")

let minihash data =
  let h = ref 1469598103934665603L in
  let mult = 1099511628211L in
  String.iter (fun c ->
    let b = Int64.of_int (Char.code c) in
    h := Int64.logxor !h b;
    h := Int64.mul !h mult
  ) data;
  Printf.sprintf "%016Lx" !h

let cmd_init () =
  if Sys.file_exists ".minigit" then
    print_endline "Repository already initialized"
  else begin
    Unix.mkdir ".minigit" 0o755;
    Unix.mkdir ".minigit/objects" 0o755;
    Unix.mkdir ".minigit/commits" 0o755;
    write_file ".minigit/index" "";
    write_file ".minigit/HEAD" ""
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
  let head = String.trim (read_file ".minigit/HEAD") in
  let parent = if head = "" then "NONE" else head in
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

let cmd_status () =
  let index = read_index () in
  if index = [] then begin
    print_endline "Staged files:";
    print_endline "(none)"
  end else begin
    print_endline "Staged files:";
    List.iter print_endline index
  end

let parse_commit content =
  let lines = String.split_on_char '\n' content in
  let parent = ref "" in
  let timestamp = ref "" in
  let message = ref "" in
  let files = ref [] in
  let in_files = ref false in
  List.iter (fun line ->
    let len = String.length line in
    if !in_files then begin
      let trimmed = String.trim line in
      if trimmed <> "" then
        files := trimmed :: !files
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

let parse_file_entry entry =
  match String.index_opt entry ' ' with
  | Some i -> (String.sub entry 0 i, String.sub entry (i + 1) (String.length entry - i - 1))
  | None -> (entry, "")

let rec log_traverse hash =
  let content = read_file (".minigit/commits/" ^ hash) in
  let (_, timestamp, message, _) = parse_commit content in
  Printf.printf "commit %s\nDate: %s\nMessage: %s\n\n" hash timestamp message;
  let (parent, _, _, _) = parse_commit content in
  if parent <> "NONE" then
    log_traverse parent

let cmd_log () =
  let head = String.trim (read_file ".minigit/HEAD") in
  if head = "" then
    print_endline "No commits"
  else
    log_traverse head

let cmd_diff c1 c2 =
  let commit_path1 = ".minigit/commits/" ^ c1 in
  let commit_path2 = ".minigit/commits/" ^ c2 in
  if not (Sys.file_exists commit_path1) || not (Sys.file_exists commit_path2) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content1 = read_file commit_path1 in
  let content2 = read_file commit_path2 in
  let (_, _, _, files1) = parse_commit content1 in
  let (_, _, _, files2) = parse_commit content2 in
  let map1 = List.map parse_file_entry files1 in
  let map2 = List.map parse_file_entry files2 in
  let all_files = List.sort_uniq String.compare
    (List.map fst map1 @ List.map fst map2) in
  List.iter (fun f ->
    let h1 = List.assoc_opt f map1 in
    let h2 = List.assoc_opt f map2 in
    match h1, h2 with
    | None, Some _ -> Printf.printf "Added: %s\n" f
    | Some _, None -> Printf.printf "Removed: %s\n" f
    | Some a, Some b when a <> b -> Printf.printf "Modified: %s\n" f
    | _ -> ()
  ) all_files

let cmd_checkout hash =
  let commit_path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists commit_path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content = read_file commit_path in
  let (_, _, _, files) = parse_commit content in
  List.iter (fun entry ->
    let (fname, blob_hash) = parse_file_entry entry in
    let blob_content = read_file (".minigit/objects/" ^ blob_hash) in
    write_file fname blob_content
  ) files;
  write_file ".minigit/HEAD" hash;
  write_file ".minigit/index" "";
  Printf.printf "Checked out %s\n" hash

let cmd_reset hash =
  let commit_path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists commit_path) then begin
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
  let commit_path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists commit_path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content = read_file commit_path in
  let (_, timestamp, message, files) = parse_commit content in
  Printf.printf "commit %s\n" hash;
  Printf.printf "Date: %s\n" timestamp;
  Printf.printf "Message: %s\n" message;
  Printf.printf "Files:\n";
  let sorted = List.sort (fun a b ->
    let (fa, _) = parse_file_entry a in
    let (fb, _) = parse_file_entry b in
    String.compare fa fb
  ) files in
  List.iter (fun entry ->
    Printf.printf "  %s\n" entry
  ) sorted

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
