let minigit_dir = ".minigit"
let objects_dir = Filename.concat minigit_dir "objects"
let commits_dir = Filename.concat minigit_dir "commits"
let index_file = Filename.concat minigit_dir "index"
let head_file = Filename.concat minigit_dir "HEAD"

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

let file_exists path =
  Sys.file_exists path

let minihash data =
  let h = ref 1469598103934665603L in
  String.iter (fun c ->
    let b = Int64.of_int (Char.code c) in
    h := Int64.logxor !h b;
    (* Multiply and mod 2^64 is automatic with Int64 overflow *)
    h := Int64.mul !h 1099511628211L
  ) data;
  Printf.sprintf "%016Lx" !h

let cmd_init () =
  if Sys.file_exists minigit_dir then (
    print_endline "Repository already initialized"
  ) else (
    Unix.mkdir minigit_dir 0o755;
    Unix.mkdir objects_dir 0o755;
    Unix.mkdir commits_dir 0o755;
    write_file index_file "";
    write_file head_file ""
  )

let read_index () =
  if not (file_exists index_file) then []
  else
    let content = read_file index_file in
    if String.length content = 0 then []
    else
      String.split_on_char '\n' content
      |> List.filter (fun s -> String.length s > 0)

let write_index lines =
  let content = if lines = [] then "" else String.concat "\n" lines ^ "\n" in
  write_file index_file content

let cmd_add filename =
  if not (file_exists filename) then (
    print_endline "File not found";
    exit 1
  );
  let content = read_file filename in
  let hash = minihash content in
  let obj_path = Filename.concat objects_dir hash in
  write_file obj_path content;
  let index = read_index () in
  if not (List.mem filename index) then
    write_index (index @ [filename])

let cmd_commit message =
  let index = read_index () in
  if index = [] then (
    print_endline "Nothing to commit";
    exit 1
  );
  let sorted_files = List.sort String.compare index in
  let parent =
    let h = read_file head_file in
    let h = String.trim h in
    if String.length h = 0 then "NONE" else h
  in
  let timestamp = int_of_float (Unix.time ()) in
  let file_lines = List.map (fun fname ->
    let content = read_file fname in
    let hash = minihash content in
    Printf.sprintf "%s %s" fname hash
  ) sorted_files in
  let commit_content = Printf.sprintf "parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n"
    parent timestamp message (String.concat "\n" file_lines) in
  let commit_hash = minihash commit_content in
  let commit_path = Filename.concat commits_dir commit_hash in
  write_file commit_path commit_content;
  write_file head_file commit_hash;
  write_file index_file "";
  Printf.printf "Committed %s\n" commit_hash

let cmd_status () =
  let index = read_index () in
  print_endline "Staged files:";
  if index = [] then
    print_endline "(none)"
  else
    List.iter print_endline index

let parse_commit content =
  let lines = String.split_on_char '\n' content in
  let get_field prefix =
    let found = List.find (fun l ->
      let plen = String.length prefix in
      String.length l >= plen && String.sub l 0 plen = prefix
    ) lines in
    String.sub found (String.length prefix) (String.length found - String.length prefix)
  in
  let parent = get_field "parent: " in
  let timestamp = get_field "timestamp: " in
  let message = get_field "message: " in
  (* Parse files section *)
  let in_files = ref false in
  let files = ref [] in
  List.iter (fun line ->
    if !in_files then (
      if String.length line > 0 then
        match String.split_on_char ' ' line with
        | [fname; hash] -> files := (fname, hash) :: !files
        | _ -> ()
    ) else if line = "files:" then
      in_files := true
  ) lines;
  (parent, timestamp, message, List.rev !files)

let cmd_log () =
  let head = String.trim (read_file head_file) in
  if String.length head = 0 then (
    print_endline "No commits"
  ) else (
    let rec walk hash =
      let commit_path = Filename.concat commits_dir hash in
      let content = read_file commit_path in
      let (parent, timestamp, message, _) = parse_commit content in
      Printf.printf "commit %s\n" hash;
      Printf.printf "Date: %s\n" timestamp;
      Printf.printf "Message: %s\n" message;
      if parent <> "NONE" then (
        print_newline ();
        walk parent
      )
    in
    walk head
  )

let cmd_diff hash1 hash2 =
  let commit_path1 = Filename.concat commits_dir hash1 in
  let commit_path2 = Filename.concat commits_dir hash2 in
  if not (file_exists commit_path1) || not (file_exists commit_path2) then (
    print_endline "Invalid commit";
    exit 1
  );
  let (_, _, _, files1) = parse_commit (read_file commit_path1) in
  let (_, _, _, files2) = parse_commit (read_file commit_path2) in
  (* Collect all filenames, sorted *)
  let all_names = List.sort_uniq String.compare
    (List.map fst files1 @ List.map fst files2) in
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
  let commit_path = Filename.concat commits_dir hash in
  if not (file_exists commit_path) then (
    print_endline "Invalid commit";
    exit 1
  );
  let (_, _, _, files) = parse_commit (read_file commit_path) in
  List.iter (fun (fname, blob_hash) ->
    let blob_path = Filename.concat objects_dir blob_hash in
    let content = read_file blob_path in
    write_file fname content
  ) files;
  write_file head_file hash;
  write_file index_file "";
  Printf.printf "Checked out %s\n" hash

let cmd_reset hash =
  let commit_path = Filename.concat commits_dir hash in
  if not (file_exists commit_path) then (
    print_endline "Invalid commit";
    exit 1
  );
  write_file head_file hash;
  write_file index_file "";
  Printf.printf "Reset to %s\n" hash

let cmd_rm filename =
  let index = read_index () in
  if not (List.mem filename index) then (
    print_endline "File not in index";
    exit 1
  );
  let new_index = List.filter (fun f -> f <> filename) index in
  write_index new_index

let cmd_show hash =
  let commit_path = Filename.concat commits_dir hash in
  if not (file_exists commit_path) then (
    print_endline "Invalid commit";
    exit 1
  );
  let (_, timestamp, message, files) = parse_commit (read_file commit_path) in
  Printf.printf "commit %s\n" hash;
  Printf.printf "Date: %s\n" timestamp;
  Printf.printf "Message: %s\n" message;
  print_endline "Files:";
  let sorted_files = List.sort (fun (a, _) (b, _) -> String.compare a b) files in
  List.iter (fun (fname, blob_hash) ->
    Printf.printf "  %s %s\n" fname blob_hash
  ) sorted_files

let () =
  let args = Array.to_list Sys.argv in
  match List.tl args with
  | ["init"] -> cmd_init ()
  | ["add"; filename] -> cmd_add filename
  | "commit" :: "-m" :: msg_parts ->
    let message = String.concat " " msg_parts in
    cmd_commit message
  | ["status"] -> cmd_status ()
  | ["log"] -> cmd_log ()
  | ["diff"; h1; h2] -> cmd_diff h1 h2
  | ["checkout"; hash] -> cmd_checkout hash
  | ["reset"; hash] -> cmd_reset hash
  | ["rm"; filename] -> cmd_rm filename
  | ["show"; hash] -> cmd_show hash
  | _ ->
    prerr_endline "Unknown command";
    exit 1
