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

let dir_exists path =
  Sys.file_exists path && Sys.is_directory path

let mkdir_p path =
  if not (dir_exists path) then
    Sys.mkdir path 0o755

let minihash data =
  let h = ref 1469598103934665603L in
  String.iter (fun c ->
    let b = Int64.of_int (Char.code c) in
    h := Int64.logxor !h b;
    (* Multiply and take mod 2^64 - Int64 wraps automatically *)
    h := Int64.mul !h 1099511628211L
  ) data;
  Printf.sprintf "%016Lx" !h

let read_index () =
  if file_exists index_file then
    let content = read_file index_file in
    if String.length content = 0 then []
    else
      let lines = String.split_on_char '\n' content in
      List.filter (fun s -> String.length s > 0) lines
  else
    []

let write_index lines =
  if lines = [] then
    write_file index_file ""
  else
    write_file index_file (String.concat "\n" lines ^ "\n")

let read_head () =
  if file_exists head_file then
    let content = read_file head_file in
    String.trim content
  else
    ""

let cmd_init () =
  if dir_exists minigit_dir then (
    print_endline "Repository already initialized";
    exit 0
  );
  mkdir_p minigit_dir;
  mkdir_p objects_dir;
  mkdir_p commits_dir;
  write_file index_file "";
  write_file head_file ""

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
  let parent = read_head () in
  let parent_str = if parent = "" then "NONE" else parent in
  let timestamp = int_of_float (Unix.time ()) in
  let sorted_files = List.sort String.compare index in
  let file_entries = List.map (fun fname ->
    let content = read_file fname in
    let hash = minihash content in
    Printf.sprintf "%s %s" fname hash
  ) sorted_files in
  let commit_content = Printf.sprintf "parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n"
    parent_str timestamp message (String.concat "\n" file_entries) in
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

let parse_commit_files content =
  let lines = String.split_on_char '\n' content in
  let rec find_files = function
    | [] -> []
    | l :: rest ->
      if l = "files:" then rest
      else find_files rest
  in
  let file_lines = find_files lines in
  List.filter_map (fun l ->
    if String.length l = 0 then None
    else
      match String.index_opt l ' ' with
      | Some i ->
        let fname = String.sub l 0 i in
        let hash = String.sub l (i + 1) (String.length l - i - 1) in
        Some (fname, hash)
      | None -> None
  ) file_lines

let get_commit_field content prefix =
  let lines = String.split_on_char '\n' content in
  let plen = String.length prefix in
  let line = List.find (fun l ->
    String.length l >= plen && String.sub l 0 plen = prefix
  ) lines in
  String.sub line plen (String.length line - plen)

let cmd_log () =
  let head = read_head () in
  if head = "" then (
    print_endline "No commits";
    exit 0
  );
  let rec walk hash =
    if hash = "" || hash = "NONE" then ()
    else begin
      let commit_path = Filename.concat commits_dir hash in
      let content = read_file commit_path in
      let parent = get_commit_field content "parent: " in
      let timestamp = get_commit_field content "timestamp: " in
      let message = get_commit_field content "message: " in
      Printf.printf "commit %s\nDate: %s\nMessage: %s\n\n" hash timestamp message;
      walk parent
    end
  in
  walk head

let cmd_diff hash1 hash2 =
  let path1 = Filename.concat commits_dir hash1 in
  let path2 = Filename.concat commits_dir hash2 in
  if not (file_exists path1) || not (file_exists path2) then (
    print_endline "Invalid commit";
    exit 1
  );
  let content1 = read_file path1 in
  let content2 = read_file path2 in
  let files1 = parse_commit_files content1 in
  let files2 = parse_commit_files content2 in
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
  let content = read_file commit_path in
  let files = parse_commit_files content in
  List.iter (fun (fname, blob_hash) ->
    let blob_path = Filename.concat objects_dir blob_hash in
    let blob_content = read_file blob_path in
    write_file fname blob_content
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
  let content = read_file commit_path in
  let timestamp = get_commit_field content "timestamp: " in
  let message = get_commit_field content "message: " in
  let files = parse_commit_files content in
  let sorted_files = List.sort (fun (a, _) (b, _) -> String.compare a b) files in
  Printf.printf "commit %s\nDate: %s\nMessage: %s\nFiles:\n" hash timestamp message;
  List.iter (fun (fname, blob_hash) ->
    Printf.printf "  %s %s\n" fname blob_hash
  ) sorted_files

let () =
  let args = Array.to_list Sys.argv in
  match List.tl args with
  | ["init"] -> cmd_init ()
  | ["add"; filename] -> cmd_add filename
  | "commit" :: "-m" :: msg :: rest ->
    let full_msg = if rest = [] then msg
      else msg ^ " " ^ String.concat " " rest in
    cmd_commit full_msg
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
