let failwith fmt = Format.kasprintf failwith fmt

let sha256sum =
  let open Digestif in
  let init = Fun.const SHA256.empty
  and push ctx str = SHA256.feed_string ctx str
  and full = Fun.const false
  and stop = SHA256.get in
  Flux.Sink { init; push; full; stop }

let is_regular filename =
  Sys.file_exists filename && not (Sys.is_directory filename)

let () =
  Miou_unix.run @@ fun () ->
  let via = Flux.Flow.identity in
  let into = sha256sum in
  let from, filename =
    match Sys.argv with
    | [| _; filename |] when is_regular filename ->
        (Flux.Source.file ~filename 0x7ff, filename)
    | [| _ |] -> (Flux.Source.in_channel stdin, "-")
    | _ -> failwith "%s [<filename>]" Sys.executable_name
  in
  let hash, leftover = Flux.Stream.run ~from ~via ~into in
  Option.iter Flux.Source.dispose leftover;
  Format.printf "%a  %s\n%!" Digestif.SHA256.pp hash filename
