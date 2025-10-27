let or_failwith fn = function Ok v -> v | Error err -> failwith (fn err)
let ( let@ ) finally fn = Fun.protect ~finally fn
let ( >>= ) = Result.bind
let is_redirect resp = Httpcats.Status.is_redirection resp.Httpcats.status

let is_opam_file (hdr, _contents) =
  let filename = Filename.basename hdr.Tar.Header.file_name in
  match (hdr.Tar.Header.link_indicator, filename) with
  | Tar.Header.Link.Normal, "opam" -> true
  | _ -> false

let to_opam_descr (hdr, contents) =
  let filename = hdr.Tar.Header.file_name in
  let opamfile =
    OpamParser.FullPos.string contents filename
    |> OpamParser.FullPos.to_opamfile
  in
  let fn = function
    | OpamParserTypes.Variable (_, "description", String (_, str)) -> Some str
    | _ -> None
  in
  match List.find_map fn opamfile.file_contents with
  | Some descr -> (filename, descr)
  | None -> (filename, "")

let from_uri uri =
  Flux.Source.with_task ~parallel:true ~size:0x7ff @@ fun q ->
  let fn _ _ resp () str =
    if not (is_redirect resp) then
      match str with
      | Some str -> Flux.Bqueue.put q str
      | None -> Flux.Bqueue.close q
  in
  Httpcats.request ~uri ~fn ()
  >>= (fun (_, ()) -> Ok ())
  |> or_failwith (Fmt.str "[httpcats]: %a" Httpcats.pp_error)

let actions = Tokenizer.[ (Whitespace, Remove); (Bert, Isolate) ]

let english =
  let fn (alg : Snowball.Language.t) = (alg :> string) = "english" in
  List.find fn Snowball.languages

let stops = List.assoc english Stopwords.words

type doc = { filename: string; tokens: (string, int) Hashtbl.t; length: int }

let only_length { length; _ } = length
let only_tokens { tokens; _ } = tokens

let freqs_of_opam (filename, descr) =
  let words = Tokenizer.run actions (Seq.return descr) in
  let stemmer = Snowball.create english in
  let@ () = fun () -> Snowball.remove stemmer in
  let tokens = Hashtbl.create 0x7ff in
  let fn word =
    let stem = Snowball.stem stemmer word in
    let stem = if List.mem stem stops then None else Some stem in
    let counter = Option.bind stem (Hashtbl.find_opt tokens) in
    match (stem, counter) with
    | Some stem, Some counter -> Hashtbl.replace tokens stem (counter + 1)
    | Some stem, None -> Hashtbl.add tokens stem 1
    | None, _ -> ()
  in
  Seq.iter fn words;
  let length = Hashtbl.length tokens in
  { filename; tokens; length }

let df =
  let open Flux in
  let fn df tokens =
    let fn token _ =
      match Hashtbl.find_opt df token with
      | Some freq -> Hashtbl.replace df token (freq + 1)
      | None -> Hashtbl.add df token 1
    in
    Hashtbl.iter fn tokens; df
  in
  Sink.fold fn (Hashtbl.create 0x7ff)

let total_length = Flux.Sink.fold Int.add 0

let bm25 () =
  let open Flux.Sink.Syntax in
  let open Flux.Sink in
  let+ docs = list
  and+ df = premap only_tokens df
  and+ total_length = premap only_length total_length
  and+ _N = length in
  let total_length = Float.of_int total_length in
  let _N = Float.of_int _N in
  let avgdl = total_length /. _N in
  let idf = Hashtbl.create 0x100 in
  let fn token freq =
    let open Float in
    let freq = of_int freq in
    Hashtbl.add idf token (log (1. +. ((_N -. freq +. 0.5) /. (freq +. 0.5))))
  in
  Hashtbl.iter fn df; (avgdl, idf, docs)

let tokenize_and_stem str =
  let tokens = Tokenizer.run actions (Seq.return str) in
  let stemmer = Snowball.create english in
  let@ () = fun () -> Snowball.remove stemmer in
  let none_if_stop word = if List.mem word stops then None else Some word in
  let fn = Fun.compose none_if_stop (Snowball.stem stemmer) in
  let tokens = Seq.filter_map fn tokens in
  List.of_seq tokens

let score (k1, b) (avgdl, idf, _) query doc =
  let fn acc token =
    match Hashtbl.find_opt doc.tokens token with
    | None -> acc
    | Some freq ->
        let freq = Float.of_int freq in
        let idf = Hashtbl.find idf token in
        let _D = Float.of_int doc.length in
        let _n = freq *. (k1 +. 1.) in
        let _m = freq +. (k1 *. (1. -. b +. (b *. _D /. avgdl))) in
        acc +. (idf *. (_n /. _m))
  in
  (doc, List.fold_left fn 0.0 query)

let query = ref None
let n = ref 50
let anon str = query := Some str
let usage = Fmt.str "%s <query>" Sys.executable_name

let args =
  [ ("-n", Arg.Set_int n, "Print the first NUM results of the query search") ]

let () =
  Miou_unix.run ~domains:2 @@ fun () ->
  Arg.parse args anon usage;
  match !query with
  | None -> assert false
  | Some query ->
      let rng = Mirage_crypto_rng_miou_unix.(initialize (module Pfortuna)) in
      let@ () = fun () -> Mirage_crypto_rng_miou_unix.kill rng in
      let from = from_uri "https://opam.ocaml.org/index.tar.gz" in
      let via =
        let open Flux.Flow in
        bstr ~len:0x7ff
        << Flux_gz.inflate
        << Flux_tar.untar
        << filter is_opam_file
        << map to_opam_descr
        << map freqs_of_opam
      in
      let into = bm25 () in
      Fmt.pr ">>> download index.tar.gz\n%!";
      let ((_, _, docs) as t), leftover = Flux.Stream.run ~from ~via ~into in
      Option.iter Flux.Source.dispose leftover;
      Fmt.pr ">>> search into %d package(s)\n%!" (List.length docs);
      let query = tokenize_and_stem query in
      let score = score (1.5, 0.75) t query in
      let from = Flux.Source.list docs in
      let via = Flux.Flow.map score in
      let into = Flux.Sink.list in
      let docs_with_scores, leftover = Flux.Stream.run ~from ~via ~into in
      Option.iter Flux.Source.dispose leftover;
      Fmt.pr ">>> sort results\n%!";
      let fn (_, a) (_, b) = Float.compare b a in
      let docs_with_scores = List.sort fn docs_with_scores in
      let from = Flux.Source.list docs_with_scores in
      let via = Flux.Flow.identity in
      let into = Flux.Sink.buffer !n in
      let results, leftover = Flux.Stream.run ~from ~via ~into in
      Option.iter Flux.Source.dispose leftover;
      Fmt.pr ">>> show %d elements\n%!" !n;
      let fn (doc, score) = Fmt.pr "%s: %f\n%!" doc.filename score in
      Array.iter fn results
