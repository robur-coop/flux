let n = ref 10
let filename = ref None
let usage = Format.asprintf "%s [-n <NUM>] [FILE]" Sys.executable_name

let is_regular filename =
  Sys.file_exists filename && not (Sys.is_directory filename)

let anon str = if is_regular str then filename := Some str

let args =
  [ ("-n", Arg.Set_int n, "Print the first NUM lines instead of the first 10") ]

let buffer len =
  if len < 0 then invalid_arg "buffer: negative buffer size";
  let flow (Flux.Sink k) =
    let init () = (k.init (), 0)
    and push (acc, idx) x =
      if idx = len then (acc, idx) else (k.push acc x, idx + 1)
    and full (acc, idx) = k.full acc || idx = len
    and stop (acc, _) = k.stop acc in
    Flux.Sink { init; push; full; stop }
  in
  { Flux.flow }

let () =
  Miou_unix.run @@ fun () ->
  Arg.parse args anon usage;
  let open Flux in
  let from =
    match !filename with
    | Some filename -> Source.file ~filename 0x7ff
    | None -> Source.in_channel stdin
  in
  let via = Flow.(split_on_char '\n' << buffer !n << map (fun x -> x ^ "\n")) in
  let into = Flux.Sink.out_channel stdout in
  let (), leftover = Flux.Stream.run ~from ~via ~into in
  Option.iter Flux.Source.dispose leftover
