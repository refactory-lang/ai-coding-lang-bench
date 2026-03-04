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
  let path = ".minigit/index" in
  if Sys.file_exists path then
    let content = read_file path in
    if String.length content = 0 then []
    else
      List.filter (fun s -> String.length s > 0)
        (String.split_on_char '\n' content)
  else []

let write_index files =
  if files = [] then
    write_file ".minigit/index" ""
  else
    write_file ".minigit/index" (String.concat "\n" files ^ "\n")

let read_head () =
  let path = ".minigit/HEAD" in
  if Sys.file_exists path then
    String.trim (read_file path)
  else ""

let cmd_init () =
  if Sys.file_exists ".minigit" then
    print_endline "Repository already initialized"
  else begin
    Sys.mkdir ".minigit" 0o755;
    Sys.mkdir ".minigit/objects" 0o755;
    Sys.mkdir ".minigit/commits" 0o755;
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
  if not (List.mem file index) then
    write_index (index @ [file])

let cmd_commit msg =
  let index = read_index () in
  if index = [] then begin
    print_endline "Nothing to commit";
    exit 1
  end;
  let parent = read_head () in
  let parent_str = if parent = "" then "NONE" else parent in
  let timestamp = int_of_float (Unix.time ()) in
  let sorted_files = List.sort String.compare index in
  let file_entries = List.map (fun f ->
    let content = read_file f in
    let hash = minihash content in
    f ^ " " ^ hash
  ) sorted_files in
  let commit_content = Printf.sprintf "parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n"
    parent_str timestamp msg (String.concat "\n" file_entries) in
  let commit_hash = minihash commit_content in
  write_file (".minigit/commits/" ^ commit_hash) commit_content;
  write_file ".minigit/HEAD" commit_hash;
  write_file ".minigit/index" "";
  Printf.printf "Committed %s\n" commit_hash

let cmd_status () =
  let index = read_index () in
  print_endline "Staged files:";
  if index = [] then
    print_endline "(none)"
  else
    List.iter print_endline index

let parse_commit_fields content =
  let lines = String.split_on_char '\n' content in
  let find_field prefix =
    let plen = String.length prefix in
    let rec search = function
      | [] -> ""
      | l :: rest ->
        if String.length l >= plen && String.sub l 0 plen = prefix then
          String.sub l plen (String.length l - plen)
        else search rest
    in
    search lines
  in
  let timestamp = find_field "timestamp: " in
  let message = find_field "message: " in
  let parent = find_field "parent: " in
  (* Parse files section *)
  let rec find_files_section = function
    | [] -> []
    | l :: rest ->
      if l = "files:" then rest
      else find_files_section rest
  in
  let file_lines = find_files_section lines in
  let files = List.filter_map (fun l ->
    if String.length l = 0 then None
    else
      match String.split_on_char ' ' l with
      | [name; hash] -> Some (name, hash)
      | _ -> None
  ) file_lines in
  (parent, timestamp, message, files)

let cmd_log () =
  let head = read_head () in
  if head = "" then
    print_endline "No commits"
  else
    let rec traverse hash first =
      if hash = "" || hash = "NONE" then ()
      else begin
        if not first then print_newline ();
        let content = read_file (".minigit/commits/" ^ hash) in
        let (parent, timestamp, message, _) = parse_commit_fields content in
        Printf.printf "commit %s\nDate: %s\nMessage: %s\n" hash timestamp message;
        if parent <> "NONE" then traverse parent false
      end
    in
    traverse head true

let cmd_diff hash1 hash2 =
  let path1 = ".minigit/commits/" ^ hash1 in
  let path2 = ".minigit/commits/" ^ hash2 in
  if not (Sys.file_exists path1) || not (Sys.file_exists path2) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content1 = read_file path1 in
  let content2 = read_file path2 in
  let (_, _, _, files1) = parse_commit_fields content1 in
  let (_, _, _, files2) = parse_commit_fields content2 in
  (* Collect all filenames *)
  let all_names = List.sort_uniq String.compare
    (List.map fst files1 @ List.map fst files2) in
  List.iter (fun name ->
    let h1 = List.assoc_opt name files1 in
    let h2 = List.assoc_opt name files2 in
    match h1, h2 with
    | None, Some _ -> Printf.printf "Added: %s\n" name
    | Some _, None -> Printf.printf "Removed: %s\n" name
    | Some a, Some b -> if a <> b then Printf.printf "Modified: %s\n" name
    | None, None -> ()
  ) all_names

let cmd_checkout hash =
  let path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content = read_file path in
  let (_, _, _, files) = parse_commit_fields content in
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
  let index = read_index () in
  if not (List.mem file index) then begin
    print_endline "File not in index";
    exit 1
  end;
  let new_index = List.filter (fun f -> f <> file) index in
  write_index new_index

let cmd_show hash =
  let path = ".minigit/commits/" ^ hash in
  if not (Sys.file_exists path) then begin
    print_endline "Invalid commit";
    exit 1
  end;
  let content = read_file path in
  let (_, timestamp, message, files) = parse_commit_fields content in
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
  | _ -> Printf.eprintf "Unknown command\n"; exit 1
