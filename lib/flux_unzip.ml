type entry = {
    filepath: string
  ; mtime: Ptime.t
  ; meth: [ `Stored | `Deflated ]
  ; crc32: Checkseum.Crc32.t
  ; csz: int64
  ; usz: int64
  ; offset: int64
}

type t = { filename: string; entries: entry list }

let ( let* ) = Result.bind
let error_msgf fmt = Fmt.kstr (fun msg -> Error (`Msg msg)) fmt
let entries { entries; _ } = entries

let really_read ic ~pos len =
  In_channel.seek ic pos;
  match In_channel.really_input_string ic len with
  | Some str -> Ok str
  | None -> error_msgf "Flux_unzip: truncated archive"

let to_ptime ~time ~date =
  let ss = time land 0x1f * 2
  and mm = (time lsr 5) land 0x3f
  and hh = (time lsr 11) land 0x1f in
  let d = date land 0x1f
  and m = (date lsr 5) land 0xf
  and y = 1980 + (date lsr 9) in
  match Ptime.of_date_time ((y, m, d), ((hh, mm, ss), 0)) with
  | Some t -> t
  | None -> Ptime.epoch

let u32_to_i64 value = Int64.logand (Int64.of_int32 value) 0xffffffffL

let find_eocd ic =
  let len = In_channel.length ic in
  let max_scan = Int64.of_int (22 + 0xffff) in
  let scan = if Int64.compare len max_scan < 0 then len else max_scan in
  let pos = Int64.sub len scan in
  let* tail = really_read ic ~pos (Int64.to_int scan) in
  let rec go idx =
    if idx < 0 then error_msgf "Flux_unzip: no end of central directory"
    else if
      String.get_int32_le tail idx = 0x06054b50l
      && idx + 22 + String.get_uint16_le tail (idx + 20) = String.length tail
    then Ok (Int64.add pos (Int64.of_int idx), String.sub tail idx 22)
    else go (idx - 1)
  in
  go (String.length tail - 22)

let find_central_directory ic =
  let* eocd_pos, eocd = find_eocd ic in
  let entries = String.get_uint16_le eocd 10 in
  let cd_size = String.get_int32_le eocd 12 in
  let cd_off = String.get_int32_le eocd 16 in
  if entries <> 0xffff && cd_size <> 0xffffffffl && cd_off <> 0xffffffffl then
    Ok (Int64.of_int entries, u32_to_i64 cd_off)
  else if Int64.compare eocd_pos 20L < 0 then
    error_msgf "Flux_unzip: missing zip64 locator"
  else
    let* locator = really_read ic ~pos:(Int64.sub eocd_pos 20L) 20 in
    if String.get_int32_le locator 0 <> 0x07064b50l then
      error_msgf "Flux_unzip: missing zip64 locator"
    else
      let eocd64_pos = String.get_int64_le locator 8 in
      let* eocd64 = really_read ic ~pos:eocd64_pos 56 in
      if String.get_int32_le eocd64 0 <> 0x06064b50l then
        error_msgf "Flux_unzip: malformed zip64 end of central directory"
      else
        let entries = String.get_int64_le eocd64 32 in
        let cd_off = String.get_int64_le eocd64 48 in
        Ok (entries, cd_off)

let parse_extra ~usz ~csz ~offset extra =
  let rec go idx usz csz offset =
    if idx + 4 > String.length extra then (usz, csz, offset)
    else begin
      let id = String.get_uint16_le extra idx in
      let sz = String.get_uint16_le extra (idx + 2) in
      if id = 0x0001 && idx + 4 + sz <= String.length extra then begin
        let jdx = ref (idx + 4) in
        let take () =
          let value = String.get_int64_le extra !jdx in
          jdx := !jdx + 8;
          value
        in
        let usz = if usz = 0xffffffffL then take () else usz in
        let csz = if csz = 0xffffffffL then take () else csz in
        let offset = if offset = 0xffffffffL then take () else offset in
        go (idx + 4 + sz) usz csz offset
      end
      else go (idx + 4 + sz) usz csz offset
    end
  in
  go 0 usz csz offset

let parse_entry ic pos =
  let* cdfh = really_read ic ~pos 46 in
  if String.get_int32_le cdfh 0 <> 0x02014b50l then
    error_msgf "Flux_unzip: malformed central directory"
  else if String.get_uint16_le cdfh 8 land 0x1 <> 0 then
    error_msgf "Flux_unzip: encrypted members are not supported"
  else
    let* meth =
      match String.get_uint16_le cdfh 10 with
      | 0 -> Ok `Stored
      | 8 -> Ok `Deflated
      | meth -> error_msgf "Flux_unzip: unsupported compression method %d" meth
    in
    let time = String.get_uint16_le cdfh 12
    and date = String.get_uint16_le cdfh 14 in
    let crc32 = Optint.of_unsigned_int32 (String.get_int32_le cdfh 16) in
    let csz = u32_to_i64 (String.get_int32_le cdfh 20) in
    let usz = u32_to_i64 (String.get_int32_le cdfh 24) in
    let name_len = String.get_uint16_le cdfh 28
    and extra_len = String.get_uint16_le cdfh 30
    and comment_len = String.get_uint16_le cdfh 32 in
    let offset = u32_to_i64 (String.get_int32_le cdfh 42) in
    let* filepath = really_read ic ~pos:(Int64.add pos 46L) name_len in
    let* extra =
      really_read ic
        ~pos:(Int64.add pos (Int64.of_int (46 + name_len)))
        extra_len
    in
    let usz, csz, offset = parse_extra ~usz ~csz ~offset extra in
    let mtime = to_ptime ~time ~date in
    let next =
      Int64.add pos (Int64.of_int (46 + name_len + extra_len + comment_len))
    in
    Ok ({ filepath; mtime; meth; crc32; csz; usz; offset }, next)

let of_filename filename =
  let process ic =
    let* entries, cd_off = find_central_directory ic in
    let rec go acc pos = function
      | 0L -> Ok (List.rev acc)
      | n ->
          let* entry, next = parse_entry ic pos in
          go (entry :: acc) next (Int64.pred n)
    in
    let* entries = go [] cd_off entries in
    Ok { filename; entries }
  in
  match In_channel.open_bin filename with
  | ic ->
      Fun.protect ~finally:(fun () -> In_channel.close ic) @@ fun () ->
      process ic
  | exception Sys_error err -> error_msgf "Flux_unzip: %s" err

let raw ~filename ~pos ~len : string Flux.source =
  let init () =
    let ic = In_channel.open_bin filename in
    match really_read ic ~pos 30 with
    | Error (`Msg msg) -> In_channel.close ic; failwith msg
    | Ok lfh ->
        if String.get_int32_le lfh 0 <> 0x04034b50l then begin
          In_channel.close ic;
          failwith "Flux_unzip: malformed local file header"
        end;
        let name_len = String.get_uint16_le lfh 26
        and extra_len = String.get_uint16_le lfh 28 in
        let data = Int64.add pos (Int64.of_int (30 + name_len + extra_len)) in
        In_channel.seek ic data; (ic, len)
  and pull (ic, rem) =
    if Int64.compare rem 0L <= 0 then None
    else
      let len =
        if Int64.compare rem 0x7ffL < 0 then Int64.to_int rem else 0x7ff
      in
      match In_channel.really_input_string ic len with
      | Some str -> Some (str, (ic, Int64.sub rem (Int64.of_int len)))
      | None -> failwith "Flux_unzip: truncated archive"
  and stop (ic, _) = In_channel.close ic in
  Flux.Source { init; pull; stop }

let stream t entry =
  let raw = raw ~filename:t.filename ~pos:entry.offset ~len:entry.csz in
  let via =
    match entry.meth with
    | `Stored -> Flux.Flow.identity
    | `Deflated -> Flux.Flow.(bstr ~len:0x7ff << Flux_de.inflate)
  in
  let stream (Flux.Sink k) =
    let crc32 = ref Checkseum.Crc32.default in
    let seen = ref 0L in
    let push acc str =
      let len = String.length str in
      crc32 := Checkseum.Crc32.digest_string str 0 len !crc32;
      seen := Int64.add !seen (Int64.of_int len);
      k.push acc str
    and stop acc =
      if Int64.equal !seen entry.usz && not (Optint.equal !crc32 entry.crc32)
      then Fmt.failwith "Flux_unzip: CRC-32 mismatch for %s" entry.filepath;
      k.stop acc
    in
    let into = Flux.Sink { init= k.init; push; full= k.full; stop } in
    let value, leftover = Flux.Stream.run ~from:raw ~via ~into in
    Option.iter Flux.Source.dispose leftover;
    value
  in
  { Flux.stream }
