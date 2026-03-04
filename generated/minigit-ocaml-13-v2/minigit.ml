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
  let index_content = read_file ".minigit/index" in
  let lines = if index_content = "" then []
    else String.split_on_char '\n' index_content
      |> List.filter (fun s -> s <> "") in
  if not (List.mem file lines) then begin
    let oc = open_out_gen [Open_append; Open_wronly] 0o644 ".minigit/index" in
    output_string oc (file ^ "\n");
    close_out oc
  end

let cmd_commit msg =
  let index_content = read_file ".minigit/index" in
  let files = String.split_on_char '\n' index_content
    |> List.filter (fun s -> s <> "") in
  if files = [] then begin
    print_endline "Nothing to commit";
    exit 1
  end;
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

let cmd_status () =
  let index_content = read_file ".minigit/index" in
  let files = String.split_on_char '\n' index_content
    |> List.filter (fun s -> s <> "") in
  print_endline "Staged files:";
  if files = [] then
    print_endline "(none)"
  else
    List.iter print_endline files

let parse_commit_content content =
  let lines = String.split_on_char '\n' content in
  let find_field prefix =
    List.find_map (fun line ->
      let plen = String.length prefix in
      if String.length line >= plen && String.sub line 0 plen = prefix then
        Some (String.sub line plen (String.length line - plen))
      else None
    ) lines
  in
  let timestamp = match find_field "timestamp: " with Some s -> s | None -> "0" in
  let message = match find_field "message: " with Some s -> s | None -> "" in
  let parent = match find_field "parent: " with Some s -> s | None -> "NONE" in
  let rec get_files = function
    | [] -> []
    | "files:" :: rest -> List.filter (fun s -> s <> "") rest
    | _ :: rest -> get_files rest
  in
  let file_entries = get_files lines in
  let files = List.map (fun entry ->
    match String.split_on_char ' ' entry with
    | [name; hash] -> (name, hash)
    | _ -> ("", "")
  ) file_entries |> List.filter (fun (n, _) -> n <> "") in
  (parent, timestamp, message, files)

let cmd_log () =
  let head_content = String.trim (read_file ".minigit/HEAD") in
  if head_content = "" then
    print_endline "No commits"
  else begin
    let rec walk hash =
      let commit_content = read_file (".minigit/commits/" ^ hash) in
      let (parent, timestamp, message, _) = parse_commit_content commit_content in
      Printf.printf "commit %s\nDate: %s\nMessage: %s\n\n" hash timestamp message;
      if parent <> "NONE" then walk parent
    in
    walk head_content
  end

let cmd_diff hash1 hash2 =
  let path1 = ".minigit/commits/" ^ hash1 in
  let path2 = ".minigit/commits/" ^ hash2 in
  if not (Sys.file_exists path1) || not (Sys.file_exists path2) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let (_, _, _, files1) = parse_commit_content (read_file path1) in
  let (_, _, _, files2) = parse_commit_content (read_file path2) in
  let all_names = List.map fst files1 @ List.map fst files2
    |> List.sort_uniq String.compare in
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
  let path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let (_, _, _, files) = parse_commit_content (read_file path) in
  List.iter (fun (name, blob_hash) ->
    let blob_content = read_file (".minigit/objects/" ^ blob_hash) in
    write_file name blob_content
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
  let lines = String.split_on_char '\n' index_content
    |> List.filter (fun s -> s <> "") in
  if not (List.mem file lines) then begin
    print_endline "File not in index";
    exit 1
  end;
  let new_lines = List.filter (fun s -> s <> file) lines in
  let new_content = if new_lines = [] then ""
    else String.concat "\n" new_lines ^ "\n" in
  write_file ".minigit/index" new_content

let cmd_show hash =
  let path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let (_, timestamp, message, files) = parse_commit_content (read_file path) in
  Printf.printf "commit %s\nDate: %s\nMessage: %s\nFiles:\n" hash timestamp message;
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) files in
  List.iter (fun (name, blob_hash) ->
    Printf.printf "  %s %s\n" name blob_hash
  ) sorted

let () =
  let args = Array.to_list Sys.argv in
  match args with
  | _ :: "init" :: _ -> cmd_init ()
  | _ :: "add" :: file :: _ -> cmd_add file
  | _ :: "commit" :: "-m" :: msg :: _ -> cmd_commit msg
  | _ :: "status" :: _ -> cmd_status ()
  | _ :: "log" :: _ -> cmd_log ()
  | _ :: "diff" :: h1 :: h2 :: _ -> cmd_diff h1 h2
  | _ :: "checkout" :: hash :: _ -> cmd_checkout hash
  | _ :: "reset" :: hash :: _ -> cmd_reset hash
  | _ :: "rm" :: file :: _ -> cmd_rm file
  | _ :: "show" :: hash :: _ -> cmd_show hash
  | _ ->
    Printf.eprintf "Usage: minigit <command>\n";
    exit 1
