type entry = {
    filepath: string
  ; mtime: Ptime.t
  ; tz_offset_s: Ptime.tz_offset_s option
  ; src: string Flux.source
  ; level: int
}

let of_filepath ?tz_offset_s ?(mtime = Ptime.epoch) ?(level = 6) filepath src =
  if level < 0 || level > 9 then
    failwith "Invalid compression level (must be in 0 and 8 included)";
  if String.length filepath >= 0x1000 then failwith "Too long filepath";
  { filepath; mtime; tz_offset_s; src; level }

let of_ptime ?tz_offset_s t =
  let (y, m, d), ((hh, mm, ss), _) = Ptime.to_date_time ?tz_offset_s t in
  let time = (ss lsr 1) + (mm lsl 5) + (hh lsl 11) in
  let date = d + (m lsl 5) + ((y - 1980) lsl 9) in
  (time, date)

let to_sink : type a s.
    push:(s -> a -> s) -> ?full:(s -> bool) -> s -> (a, s) Flux.sink =
 fun ~push ?full acc ->
  let init () = acc
  and full = match full with Some full -> full | None -> Fun.const false
  and stop acc = acc in
  Flux.Sink { init; push; full; stop }

let deflate ~level from into =
  let crc32 = ref Checkseum.Crc32.default in
  let csz = ref 0L in
  let usz = ref 0L in
  let on_source str =
    let len = String.length str in
    crc32 := Checkseum.Crc32.digest_string str 0 len !crc32;
    usz := Int64.add !usz (Int64.of_int len)
  in
  let on_deflated str =
    csz := Int64.add !csz (Int64.of_int (String.length str))
  in
  match level with
  | 0 ->
      let via =
        let open Flux.Flow in
        tap on_source << tap on_deflated
      in
      let acc, src = Flux.Stream.run ~from ~via ~into in
      Option.iter Flux.Source.dispose src;
      (acc, !crc32, !csz, !usz)
  | level ->
      let cfg = Flux_de.config ~level () in
      let via =
        let open Flux.Flow in
        tap on_source
        << bstr ~len:0x1000
        << Flux_de.deflate ~cfg
        << tap on_deflated
      in
      let acc, src = Flux.Stream.run ~from ~via ~into in
      Option.iter Flux.Source.dispose src;
      (acc, !crc32, !csz, !usz)

type cdfh = {
    filepath: string
  ; meth: [ `Stored | `Deflated ]
  ; mtime: Ptime.t
  ; tz_offset_s: Ptime.tz_offset_s option
  ; crc32: Checkseum.Crc32.t
  ; csz: int64
  ; usz: int64
  ; offset: int64
}

module S = Set.Make (String)

let rev_uniq entries =
  let rec rev acc seen = function
    | [] -> acc
    | cdfh :: entries ->
        if S.mem cdfh.filepath seen then rev acc seen entries
        else rev (cdfh :: acc) (S.add cdfh.filepath seen) entries
  in
  rev [] S.empty entries

let zip =
  let ( let* ) = Result.bind in
  let open Flux in
  let flow (Sink k) =
    let init () = Ok (k.init (), [], 0L) in
    let emit acc str =
      match k.full acc with
      | true -> Error (`Full acc)
      | false -> Ok (k.push acc str)
    in
    let push acc { filepath; mtime; tz_offset_s; level; src } =
      match acc with
      | Error _ as err -> err
      | Ok (acc, entries, offset) ->
          let filepath =
            if Sys.os_type = "Win32" then
              String.map (function '\\' -> '/' | chr -> chr) filepath
            else filepath
          in
          let time, date = of_ptime ?tz_offset_s mtime in
          let buf = Bytes.create 30 in
          Bytes.set_int32_le buf 0 0x04034b50l;
          Bytes.set_uint16_le buf 4 45;
          Bytes.set_uint16_le buf 6 0b1000;
          Bytes.set_uint16_le buf 8 (if level = 0 then 0 else 8);
          Bytes.set_uint16_le buf 10 time;
          Bytes.set_uint16_le buf 12 date;
          Bytes.set_int32_le buf 14 0l;
          Bytes.set_int32_le buf 18 0xffffffffl;
          Bytes.set_int32_le buf 22 0xffffffffl;
          Bytes.set_uint16_le buf 26 (String.length filepath);
          Bytes.set_uint16_le buf 28 20;
          let* acc = emit acc (Bytes.unsafe_to_string buf) in
          let* acc = emit acc filepath in
          let buf = Bytes.create 20 in
          Bytes.set_uint16_le buf 0 0x0001;
          Bytes.set_uint16_le buf 2 16;
          Bytes.set_int64_le buf 4 0xffffffffffffffffL;
          Bytes.set_int64_le buf 12 0xffffffffffffffffL;
          let* acc = emit acc (Bytes.unsafe_to_string buf) in
          let into = to_sink ~push:k.push ~full:k.full acc in
          let acc, crc32, csz, usz = deflate ~level src into in
          let buf = Bytes.create 24 in
          Bytes.set_int32_le buf 0 0x08074b50l;
          Bytes.set_int32_le buf 4 (Optint.to_unsigned_int32 crc32);
          Bytes.set_int64_le buf 8 csz;
          Bytes.set_int64_le buf 16 usz;
          let* acc = emit acc (Bytes.unsafe_to_string buf) in
          let meth = if level = 0 then `Stored else `Deflated in
          let cdfh =
            { filepath; meth; mtime; tz_offset_s; crc32; usz; csz; offset }
          in
          let len = Int64.of_int (30 + String.length filepath + 20 + 24) in
          let len = Int64.add len csz in
          Ok (acc, cdfh :: entries, Int64.add offset len)
    in
    let full = function Ok (acc, _, _) | Error (`Full acc) -> k.full acc in
    let stop state =
      let close (acc, entries, start_cd) =
        let entries = rev_uniq entries in
        let rec go acc start_ecd = function
          | [] -> Ok (acc, start_ecd)
          | { filepath; meth; mtime; tz_offset_s; crc32; csz; usz; offset }
            :: entries ->
              let buf = Bytes.create 46 in
              Bytes.set_int32_le buf 0 0x02014b50l;
              Bytes.set_uint16_le buf 4 45;
              Bytes.set_uint16_le buf 6 45;
              Bytes.set_uint16_le buf 8 0b1000;
              Bytes.set_uint16_le buf 10 (if meth = `Stored then 0 else 8);
              let time, date = of_ptime ?tz_offset_s mtime in
              Bytes.set_uint16_le buf 12 time;
              Bytes.set_uint16_le buf 14 date;
              Bytes.set_int32_le buf 16 (Optint.to_unsigned_int32 crc32);
              Bytes.set_int32_le buf 20 0xffffffffl;
              Bytes.set_int32_le buf 24 0xffffffffl;
              Bytes.set_uint16_le buf 28 (String.length filepath);
              Bytes.set_uint16_le buf 30 28;
              Bytes.set_uint16_le buf 32 0;
              Bytes.set_uint16_le buf 34 0;
              Bytes.set_uint16_le buf 36 0;
              Bytes.set_int32_le buf 38 0l;
              Bytes.set_int32_le buf 42 0xffffffffl;
              let* acc = emit acc (Bytes.unsafe_to_string buf) in
              let* acc = emit acc filepath in
              let buf = Bytes.create 28 in
              Bytes.set_uint16_le buf 0 0x0001;
              Bytes.set_uint16_le buf 2 24;
              Bytes.set_int64_le buf 4 usz;
              Bytes.set_int64_le buf 12 csz;
              Bytes.set_int64_le buf 20 offset;
              let* acc = emit acc (Bytes.unsafe_to_string buf) in
              let len = Int64.of_int (46 + String.length filepath + 28) in
              let start_ecd = Int64.add start_ecd len in
              go acc start_ecd entries
        in
        let* acc, start_ecd = go acc start_cd entries in
        let cd_size = Int64.sub start_ecd start_cd in
        let buf = Bytes.create 98 in
        Bytes.set_int32_le buf 0 0x06064b50l;
        Bytes.set_int64_le buf 4 44L;
        Bytes.set_uint16_le buf 12 45;
        Bytes.set_uint16_le buf 14 45;
        Bytes.set_int32_le buf 16 0l;
        Bytes.set_int32_le buf 20 0l;
        let num_entries = Int64.of_int (List.length entries) in
        Bytes.set_int64_le buf 24 num_entries;
        Bytes.set_int64_le buf 32 num_entries;
        Bytes.set_int64_le buf 40 cd_size;
        Bytes.set_int64_le buf 48 start_cd;
        Bytes.set_int32_le buf 56 0x07064b50l;
        Bytes.set_int32_le buf 60 0l;
        Bytes.set_int64_le buf 64 start_ecd;
        Bytes.set_int32_le buf 72 0l;
        Bytes.set_int32_le buf 76 0x06054b50l;
        Bytes.set_uint16_le buf 80 0xffff;
        Bytes.set_uint16_le buf 82 0xffff;
        Bytes.set_uint16_le buf 84 0xffff;
        Bytes.set_uint16_le buf 86 0xffff;
        Bytes.set_int32_le buf 88 0xffffffffl;
        Bytes.set_int32_le buf 92 0xffffffffl;
        Bytes.set_uint16_le buf 96 0;
        let* acc = emit acc (Bytes.unsafe_to_string buf) in
        Ok acc
      in
      match Result.bind state close with
      | Ok acc | Error (`Full acc) -> k.stop acc
    in
    Sink { init; push; full; stop }
  in
  { flow }
