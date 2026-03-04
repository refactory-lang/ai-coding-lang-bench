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

let parse_index () =
  let index_content = read_file ".minigit/index" in
  if String.length index_content = 0 then []
  else String.split_on_char '\n' index_content |> List.filter (fun s -> s <> "")

let parse_commit_files commit_content =
  let lines = String.split_on_char '\n' commit_content in
  let rec find_files = function
    | [] -> []
    | "files:" :: rest -> rest
    | _ :: rest -> find_files rest
  in
  find_files lines
  |> List.filter (fun s -> s <> "")
  |> List.map (fun line ->
    match String.split_on_char ' ' line with
    | [fname; hash] -> (fname, hash)
    | _ -> ("", ""))
  |> List.filter (fun (f, _) -> f <> "")

let find_field lines prefix =
  let pl = String.length prefix in
  List.find (fun l -> String.length l >= pl && String.sub l 0 pl = prefix) lines
  |> fun l -> String.sub l pl (String.length l - pl)

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
  write_file (Printf.sprintf ".minigit/objects/%s" hash) content;
  let entries = parse_index () in
  if not (List.mem file entries) then begin
    let oc = open_out_gen [Open_append; Open_wronly] 0o644 ".minigit/index" in
    output_string oc (file ^ "\n");
    close_out oc
  end

let cmd_commit msg =
  let entries = parse_index () in
  if entries = [] then begin
    print_endline "Nothing to commit";
    exit 1
  end;
  let sorted = List.sort String.compare entries in
  let head_content = read_file ".minigit/HEAD" |> String.trim in
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
  write_file (Printf.sprintf ".minigit/commits/%s" commit_hash) commit_content;
  write_file ".minigit/HEAD" commit_hash;
  write_file ".minigit/index" "";
  Printf.printf "Committed %s\n" commit_hash

let cmd_status () =
  let entries = parse_index () in
  print_endline "Staged files:";
  if entries = [] then
    print_endline "(none)"
  else
    List.iter print_endline entries

let cmd_log () =
  let head_content = read_file ".minigit/HEAD" |> String.trim in
  if head_content = "" then
    print_endline "No commits"
  else begin
    let rec walk hash =
      let commit_content = read_file (Printf.sprintf ".minigit/commits/%s" hash) in
      let lines = String.split_on_char '\n' commit_content in
      let parent = find_field lines "parent: " in
      let timestamp = find_field lines "timestamp: " in
      let message = find_field lines "message: " in
      Printf.printf "commit %s\nDate: %s\nMessage: %s\n\n" hash timestamp message;
      if parent <> "NONE" then walk parent
    in
    walk head_content
  end

let cmd_diff hash1 hash2 =
  let path1 = Printf.sprintf ".minigit/commits/%s" hash1 in
  let path2 = Printf.sprintf ".minigit/commits/%s" hash2 in
  if not (Sys.file_exists path1) || not (Sys.file_exists path2) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let files1 = parse_commit_files (read_file path1) in
  let files2 = parse_commit_files (read_file path2) in
  let all_files =
    let f1 = List.map fst files1 in
    let f2 = List.map fst files2 in
    List.sort_uniq String.compare (f1 @ f2)
  in
  List.iter (fun fname ->
    let in1 = List.assoc_opt fname files1 in
    let in2 = List.assoc_opt fname files2 in
    match in1, in2 with
    | None, Some _ -> Printf.printf "Added: %s\n" fname
    | Some _, None -> Printf.printf "Removed: %s\n" fname
    | Some h1, Some h2 -> if h1 <> h2 then Printf.printf "Modified: %s\n" fname
    | None, None -> ()
  ) all_files

let cmd_checkout hash =
  let path = Printf.sprintf ".minigit/commits/%s" hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let commit_content = read_file path in
  let files = parse_commit_files commit_content in
  List.iter (fun (fname, blob_hash) ->
    let blob_path = Printf.sprintf ".minigit/objects/%s" blob_hash in
    let content = read_file blob_path in
    write_file fname content
  ) files;
  write_file ".minigit/HEAD" hash;
  write_file ".minigit/index" "";
  Printf.printf "Checked out %s\n" hash

let cmd_reset hash =
  let path = Printf.sprintf ".minigit/commits/%s" hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  write_file ".minigit/HEAD" hash;
  write_file ".minigit/index" "";
  Printf.printf "Reset to %s\n" hash

let cmd_rm file =
  let entries = parse_index () in
  if not (List.mem file entries) then begin
    print_endline "File not in index";
    exit 1
  end;
  let new_entries = List.filter (fun f -> f <> file) entries in
  let content = if new_entries = [] then ""
    else String.concat "\n" new_entries ^ "\n" in
  write_file ".minigit/index" content

let cmd_show hash =
  let path = Printf.sprintf ".minigit/commits/%s" hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let commit_content = read_file path in
  let lines = String.split_on_char '\n' commit_content in
  let timestamp = find_field lines "timestamp: " in
  let message = find_field lines "message: " in
  let files = parse_commit_files commit_content in
  Printf.printf "commit %s\nDate: %s\nMessage: %s\nFiles:\n" hash timestamp message;
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
