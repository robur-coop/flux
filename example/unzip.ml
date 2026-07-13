open Mkdir_p

let archive = ref None
let output = ref String.empty

let anon str =
  if Sys.file_exists str && Sys.is_regular_file str then archive := Some str
  else Fmt.failwith "%S is not an existing regular archive" str

let usage = Fmt.str "%s [-o directory/] archive.zip" Sys.executable_name

let args =
  [ ("-o", Arg.Set_string output, "Extract files into the given directory") ]

let () =
  Arg.parse args anon usage;
  if Option.is_none !archive then Fmt.failwith "No archive specified";
  if !output = String.empty then Fmt.failwith "No output directory specified";
  let archive = Option.get !archive in
  let output = !output in
  mkdir_p output 0o755;
  match Flux_unzip.of_filename archive with
  | Error (`Msg msg) -> Fmt.failwith "%s: %s" Sys.executable_name msg
  | Ok t ->
      let fn entry =
        let stream = Flux_unzip.stream t entry in
        let filename = Filename.concat output entry.Flux_unzip.filepath in
        mkdir_p (Filename.dirname filename) 0o755;
        let into = Flux.Sink.file ~filename in
        Flux.Stream.into into stream
      in
      List.iter fn (Flux_unzip.entries t)
