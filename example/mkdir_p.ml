let mkdir dirpath perm =
  try Sys.mkdir dirpath perm with
  | Sys_error _ when Sys.file_exists dirpath && Sys.is_directory dirpath -> ()
  | exn -> raise exn

let mkdir_p path perm =
  let open Filename in
  let rec split_path acc p =
    let parent = dirname p in
    let base = basename p in
    if p = parent || p = "." || p = "/" then if p = "/" then "/" :: acc else acc
    else split_path (base :: acc) parent
  in
  let components = split_path [] path in
  let fn current_base dir =
    let next_path = concat current_base dir in
    mkdir next_path perm; next_path
  in
  let _ = List.fold_left fn (if path.[0] = '/' then "/" else ".") components in
  ()
