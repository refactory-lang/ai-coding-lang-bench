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

let cmd_status () =
  let index_lines = read_index () in
  if index_lines = [] then
    print_endline "Staged files:\n(none)"
  else begin
    print_endline "Staged files:";
    List.iter print_endline index_lines
  end

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

let parse_commit_files content =
  let lines = String.split_on_char '\n' content in
  let rec find_files = function
    | [] -> []
    | line :: rest ->
      if line = "files:" then rest
      else find_files rest
  in
  let file_lines = find_files lines in
  List.filter_map (fun line ->
    let line = String.trim line in
    if String.length line = 0 then None
    else
      match String.index_opt line ' ' with
      | Some i ->
        let name = String.sub line 0 i in
        let hash = String.sub line (i + 1) (String.length line - i - 1) in
        Some (name, hash)
      | None -> None
  ) file_lines

let cmd_diff hash1 hash2 =
  let commit_path1 = commits_dir ^ "/" ^ hash1 in
  let commit_path2 = commits_dir ^ "/" ^ hash2 in
  if not (Sys.file_exists commit_path1) || not (Sys.file_exists commit_path2) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let files1 = parse_commit_files (read_file commit_path1) in
  let files2 = parse_commit_files (read_file commit_path2) in
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
  let commit_path = commits_dir ^ "/" ^ hash in
  if not (Sys.file_exists commit_path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content = read_file commit_path in
  let files = parse_commit_files content in
  List.iter (fun (name, blob_hash) ->
    let blob_content = read_file (objects_dir ^ "/" ^ blob_hash) in
    write_file name blob_content
  ) files;
  write_file head_file hash;
  write_file index_file "";
  Printf.printf "Checked out %s\n" hash

let cmd_reset hash =
  let commit_path = commits_dir ^ "/" ^ hash in
  if not (Sys.file_exists commit_path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  write_file head_file hash;
  write_file index_file "";
  Printf.printf "Reset to %s\n" hash

let cmd_rm filename =
  let index_lines = read_index () in
  if not (List.mem filename index_lines) then begin
    print_endline "File not in index";
    exit 1
  end;
  let new_lines = List.filter (fun f -> f <> filename) index_lines in
  let content = if new_lines = [] then ""
    else String.concat "\n" new_lines ^ "\n" in
  write_file index_file content

let cmd_show hash =
  let commit_path = commits_dir ^ "/" ^ hash in
  if not (Sys.file_exists commit_path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content = read_file commit_path in
  let lines = String.split_on_char '\n' content in
  let timestamp = parse_commit_field lines "timestamp: " in
  let message = parse_commit_field lines "message: " in
  let files = parse_commit_files content in
  Printf.printf "commit %s\nDate: %s\nMessage: %s\nFiles:\n" hash timestamp message;
  List.iter (fun (name, blob_hash) ->
    Printf.printf "  %s %s\n" name blob_hash
  ) (List.sort (fun (a, _) (b, _) -> String.compare a b) files)

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
  | "status" -> cmd_status ()
  | "log" -> cmd_log ()
  | "diff" ->
    if argc < 4 then begin
      Printf.eprintf "Usage: minigit diff <commit1> <commit2>\n";
      exit 1
    end;
    cmd_diff args.(2) args.(3)
  | "checkout" ->
    if argc < 3 then begin
      Printf.eprintf "Usage: minigit checkout <commit_hash>\n";
      exit 1
    end;
    cmd_checkout args.(2)
  | "reset" ->
    if argc < 3 then begin
      Printf.eprintf "Usage: minigit reset <commit_hash>\n";
      exit 1
    end;
    cmd_reset args.(2)
  | "rm" ->
    if argc < 3 then begin
      Printf.eprintf "Usage: minigit rm <file>\n";
      exit 1
    end;
    cmd_rm args.(2)
  | "show" ->
    if argc < 3 then begin
      Printf.eprintf "Usage: minigit show <commit_hash>\n";
      exit 1
    end;
    cmd_show args.(2)
  | cmd ->
    Printf.eprintf "Unknown command: %s\n" cmd;
    exit 1
