let minigit_dir = ".minigit"
let objects_dir = ".minigit/objects"
let commits_dir = ".minigit/commits"
let index_file = ".minigit/index"
let head_file = ".minigit/HEAD"

let minihash data =
  let h = ref 1469598103934665603L in
  String.iter (fun c ->
    let b = Int64.of_int (Char.code c) in
    h := Int64.logxor !h b;
    h := Int64.mul !h 1099511628211L
  ) data;
  Printf.sprintf "%016Lx" !h

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

let read_lines path =
  if not (Sys.file_exists path) then []
  else
    let content = read_file path in
    if content = "" then []
    else
      String.split_on_char '\n' content
      |> List.filter (fun s -> s <> "")

let cmd_init () =
  if Sys.file_exists minigit_dir then
    print_endline "Repository already initialized"
  else begin
    Sys.mkdir minigit_dir 0o755;
    Sys.mkdir objects_dir 0o755;
    Sys.mkdir commits_dir 0o755;
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
  let lines = read_lines index_file in
  if not (List.mem filename lines) then begin
    let oc = open_out_gen [Open_append; Open_creat; Open_binary] 0o644 index_file in
    output_string oc (filename ^ "\n");
    close_out oc
  end

let cmd_commit message =
  let lines = read_lines index_file in
  if lines = [] then begin
    print_endline "Nothing to commit";
    exit 1
  end;
  let sorted_files = List.sort String.compare lines in
  let file_entries = List.map (fun fname ->
    let content = read_file fname in
    let hash = minihash content in
    fname ^ " " ^ hash
  ) sorted_files in
  let head_content = String.trim (read_file head_file) in
  let parent = if head_content = "" then "NONE" else head_content in
  let timestamp = int_of_float (Unix.time ()) in
  let commit_content = Printf.sprintf "parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n"
    parent timestamp message (String.concat "\n" file_entries) in
  let commit_hash = minihash commit_content in
  write_file (commits_dir ^ "/" ^ commit_hash) commit_content;
  write_file head_file commit_hash;
  write_file index_file "";
  Printf.printf "Committed %s\n" commit_hash

let cmd_log () =
  let head_content = String.trim (read_file head_file) in
  if head_content = "" then
    print_endline "No commits"
  else
    let rec traverse hash =
      let content = read_file (commits_dir ^ "/" ^ hash) in
      let lines = String.split_on_char '\n' content in
      let parent = ref "" in
      let timestamp = ref "" in
      let message = ref "" in
      List.iter (fun line ->
        let len = String.length line in
        if len >= 8 && String.sub line 0 8 = "parent: " then
          parent := String.sub line 8 (len - 8)
        else if len >= 11 && String.sub line 0 11 = "timestamp: " then
          timestamp := String.sub line 11 (len - 11)
        else if len >= 9 && String.sub line 0 9 = "message: " then
          message := String.sub line 9 (len - 9)
      ) lines;
      Printf.printf "commit %s\nDate: %s\nMessage: %s\n\n" hash !timestamp !message;
      if !parent <> "NONE" then
        traverse !parent
    in
    traverse head_content

let cmd_status () =
  let lines = read_lines index_file in
  print_endline "Staged files:";
  if lines = [] then
    print_endline "(none)"
  else
    List.iter print_endline lines

let parse_commit_files content =
  let lines = String.split_on_char '\n' content in
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

let cmd_diff hash1 hash2 =
  let path1 = commits_dir ^ "/" ^ hash1 in
  let path2 = commits_dir ^ "/" ^ hash2 in
  if not (Sys.file_exists path1) || not (Sys.file_exists path2) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let files1 = parse_commit_files (read_file path1) in
  let files2 = parse_commit_files (read_file path2) in
  let all_names = List.sort_uniq String.compare
    (List.map fst files1 @ List.map fst files2) in
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
  let path = commits_dir ^ "/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content = read_file path in
  let files = parse_commit_files content in
  List.iter (fun (fname, blob_hash) ->
    let blob = read_file (objects_dir ^ "/" ^ blob_hash) in
    write_file fname blob
  ) files;
  write_file head_file hash;
  write_file index_file "";
  Printf.printf "Checked out %s\n" hash

let cmd_reset hash =
  let path = commits_dir ^ "/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  write_file head_file hash;
  write_file index_file "";
  Printf.printf "Reset to %s\n" hash

let cmd_rm filename =
  let lines = read_lines index_file in
  if not (List.mem filename lines) then begin
    print_endline "File not in index";
    exit 1
  end;
  let remaining = List.filter (fun f -> f <> filename) lines in
  let content = if remaining = [] then ""
    else String.concat "\n" remaining ^ "\n" in
  write_file index_file content

let cmd_show hash =
  let path = commits_dir ^ "/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content = read_file path in
  let lines = String.split_on_char '\n' content in
  let timestamp = ref "" in
  let message = ref "" in
  List.iter (fun line ->
    let len = String.length line in
    if len >= 11 && String.sub line 0 11 = "timestamp: " then
      timestamp := String.sub line 11 (len - 11)
    else if len >= 9 && String.sub line 0 9 = "message: " then
      message := String.sub line 9 (len - 9)
  ) lines;
  let files = parse_commit_files content in
  let sorted_files = List.sort (fun (a, _) (b, _) -> String.compare a b) files in
  Printf.printf "commit %s\nDate: %s\nMessage: %s\nFiles:\n" hash !timestamp !message;
  List.iter (fun (fname, blob_hash) ->
    Printf.printf "  %s %s\n" fname blob_hash
  ) sorted_files

let () =
  let args = Array.to_list Sys.argv in
  match List.tl args with
  | ["init"] -> cmd_init ()
  | ["add"; filename] -> cmd_add filename
  | ["commit"; "-m"; message] -> cmd_commit message
  | ["status"] -> cmd_status ()
  | ["log"] -> cmd_log ()
  | ["diff"; h1; h2] -> cmd_diff h1 h2
  | ["checkout"; hash] -> cmd_checkout hash
  | ["reset"; hash] -> cmd_reset hash
  | ["rm"; filename] -> cmd_rm filename
  | ["show"; hash] -> cmd_show hash
  | _ ->
    Printf.eprintf "Unknown command\n";
    exit 1
