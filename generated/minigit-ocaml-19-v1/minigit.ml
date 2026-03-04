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

let cmd_log () =
  let head = String.trim (read_file head_file) in
  if String.length head = 0 then (
    print_endline "No commits"
  ) else (
    let rec walk hash =
      let commit_path = Filename.concat commits_dir hash in
      let content = read_file commit_path in
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

let () =
  let args = Array.to_list Sys.argv in
  match List.tl args with
  | ["init"] -> cmd_init ()
  | ["add"; filename] -> cmd_add filename
  | "commit" :: "-m" :: msg_parts ->
    let message = String.concat " " msg_parts in
    cmd_commit message
  | ["log"] -> cmd_log ()
  | _ ->
    prerr_endline "Unknown command";
    exit 1
