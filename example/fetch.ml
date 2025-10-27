let ( let@ ) finally fn = Fun.protect ~finally fn
let ( >>= ) = Result.bind
let uri = ref None
let output = ref None
let anon str = uri := Some str
let usage = Fmt.str "%s -o <file> <uri>" Sys.executable_name
let is_redirection resp = Httpcats.Status.is_redirection resp.Httpcats.status
let or_failwith fn = function Ok v -> v | Error err -> failwith (fn err)

let args =
  [ ("-o", Arg.String (fun str -> output := Some str), "The output file") ]

let sizes = [| "B"; "KiB"; "MiB"; "GiB"; "TiB"; "PiB"; "EiB"; "ZiB"; "YiB" |]

let bytes_to_size ?(decimals = 2) ppf = function
  | 0 -> Fmt.string ppf "0 byte"
  | n ->
      let n = float_of_int n in
      let i = Float.floor (Float.log n /. Float.log 1024.) in
      let r = n /. Float.pow 1024. i in
      Fmt.pf ppf "%.*f %s" decimals r sizes.(int_of_float i)

let line total =
  let open Progress.Line in
  let style = if Fmt.utf_8 Fmt.stdout then `UTF8 else `ASCII in
  match total with
  | Some total ->
      let width = `Fixed 30 in
      let metric = bytes_to_size ~decimals:2 in
      list [ bar ~style ~width total; bytes; constf " / %a" metric total ]
  | None ->
      let frames = [ "⠋"; "⠙"; "⠹"; "⠸"; "⠼"; "⠴"; "⠦"; "⠧"; "⠇"; "⠏" ] in
      let spin = spinner ~frames () in
      list [ spin; bytes; bytes_per_sec ]

let progress length =
  let open Progress in
  let config = Config.v ~ppf:Fmt.stdout () in
  let fn state str =
    match state with
    | Some (reporter, display) ->
        reporter (String.length str);
        Some (reporter, display)
    | None ->
        let length = Miou.Computation.await_exn length in
        let line = line length in
        let display = Multi.line line |> Display.start ~config in
        let[@warning "-8"] Reporter.[ reporter ] = Display.reporters display in
        reporter (String.length str);
        Some (reporter, display)
  in
  Flux.Sink.fold fn None

let set_length length (resp : Httpcats.response) =
  let hdrs = resp.Httpcats.headers in
  let content_length = Httpcats.Headers.get hdrs "content-length" in
  let value = Option.bind content_length int_of_string_opt in
  ignore (Miou.Computation.try_return length value)

let () =
  Miou_unix.run @@ fun () ->
  Arg.parse args anon usage;
  match (!uri, !output) with
  | None, _ | _, None -> Fmt.epr "%s\n%!" usage; exit 1
  | Some uri, Some output ->
      let rng = Mirage_crypto_rng_miou_unix.(initialize (module Pfortuna)) in
      let@ () = fun () -> Mirage_crypto_rng_miou_unix.kill rng in
      let length = Miou.Computation.create () in
      let from =
        Flux.Source.with_task ~parallel:true ~size:0x7ff @@ fun q ->
        let fn _ _ resp () str =
          if not (is_redirection resp) then
            let () = set_length length resp in
            match str with
            | Some str -> Flux.Bqueue.put q str
            | None -> Flux.Bqueue.close q
        in
        Httpcats.request ~uri ~fn ()
        >>= (fun (_, ()) -> Ok ())
        |> or_failwith (Fmt.str "%a" Httpcats.pp_error)
      in
      let via = Flux.Flow.identity in
      let into =
        let open Flux.Sink.Syntax in
        let ( and+ ) = Flux.Sink.both in
        let+ () = Flux.Sink.file ~filename:output
        and+ display = progress length in
        let display = Option.map snd display in
        Option.iter Progress.Display.finalise display
      in
      let (), leftover = Flux.Stream.run ~from ~via ~into in
      Option.iter Flux.Source.dispose leftover
