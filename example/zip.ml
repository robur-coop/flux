let failwithf fmt = Format.kasprintf failwith fmt
let files = ref []

let anon str =
  if Sys.file_exists str && Sys.is_regular_file str then files := str :: !files
  else failwithf "%S is not an existing regular file" str

let usage = Format.asprintf "%s [file...]" Sys.executable_name

let filepath_to_entry filename =
  let src = Flux.Source.file ~filename 0x7ff in
  Flux_zip.of_filepath ~mtime:(Ptime_clock.now ()) filename src

let () =
  Arg.parse [] anon usage;
  let entries = List.map filepath_to_entry !files in
  let from = Flux.Source.list entries in
  let into = Flux.Sink.out_channel stdout in
  let via = Flux_zip.zip in
  let (), src = Flux.Stream.run ~from ~via ~into in
  Option.iter Flux.Source.dispose src
