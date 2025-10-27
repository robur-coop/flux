module Buf = struct
  type t = { mutable buf: bytes; mutable pos: int; mutable len: int }

  let create len = { buf= Bytes.create len; pos= 0; len= 0 }
  let max t = t.len

  let get t len =
    if len > t.len then Error `Not_enough
    else begin
      let str = Bytes.sub_string t.buf t.pos len in
      t.pos <- t.pos + len;
      t.len <- t.len - len;
      if t.len = 0 then t.pos <- 0;
      Ok str
    end

  let compress t =
    if t.pos > 0 then begin
      Bytes.blit t.buf t.pos t.buf 0 t.len;
      t.pos <- 0
    end

  let extend t more =
    assert (t.pos = 0);
    let len = ref t.len in
    while t.len + more > !len do
      len := 2 * !len
    done;
    if !len > Sys.max_string_length then begin
      if t.len + more <= Sys.max_string_length then len := Sys.max_string_length
      else failwith "Buf.extend: cannot grow buffer"
    end;
    let buf = Bytes.create !len in
    Bytes.blit t.buf 0 buf 0 t.len;
    t.buf <- buf

  let rem t = Bytes.length t.buf - (t.pos + t.len)

  let put t str =
    let len = String.length str in
    if rem t < len then compress t;
    if rem t < len then extend t len;
    Bytes.blit_string str 0 t.buf (t.pos + t.len) len;
    t.len <- t.len + len

  let skip t len =
    if t.len < len then invalid_arg "Buf.skip";
    t.pos <- t.pos + len;
    t.len <- t.len - len;
    if t.len = 0 then t.pos <- 0
end

let is_enough buf hdr =
  let len = Int64.to_int hdr.Tar.Header.file_size in
  Buf.max buf >= len

let _pp ppf = function
  | Ok _ -> Format.fprintf ppf "<Ok>"
  | Error `Eof -> Format.fprintf ppf "<Eof>"
  | Error (`Fatal _) -> Format.fprintf ppf "<Fatal>"

let untar =
  let open Flux in
  let flow (Sink k) =
    let rec unfold acc buf = function
      | Ok (tar, Some (`Read req), _) when Buf.max buf >= req ->
          let data = Result.get_ok (Buf.get buf req) in
          unfold acc buf (Tar.decode tar data)
      | Ok (tar, Some (`Skip rem), _) when Buf.max buf >= rem ->
          Buf.skip buf rem;
          unfold acc buf (Ok (tar, None, None))
      | Ok (tar, Some (`Header hdr), _) when is_enough buf hdr ->
          let len = Int64.to_int hdr.Tar.Header.file_size in
          (* Format.eprintf "[+] %s (%d byte(s))\n%!" hdr.Tar.Header.file_name len; *)
          let contents = Result.get_ok (Buf.get buf len) in
          let acc = k.push acc (hdr, contents) in
          if k.full acc then (acc, buf, Error `Eof)
          else
            let rem = Tar.Header.compute_zero_padding_length hdr in
            unfold acc buf (Ok (tar, Some (`Skip rem), None))
      | Ok (tar, None, _) when Buf.max buf >= Tar.Header.length ->
          let data = Result.get_ok (Buf.get buf Tar.Header.length) in
          unfold acc buf (Tar.decode tar data)
      | state ->
          (* Format.eprintf "[+] stop with: %a\n%!" pp state; *)
          (acc, buf, state)
    in
    let rec finalise acc buf = function
      | Ok (tar, Some (`Read req), _) when Buf.max buf >= req ->
          let data = Result.get_ok (Buf.get buf req) in
          finalise acc buf (Tar.decode tar data)
      | Ok (tar, Some (`Skip rem), _) when Buf.max buf >= rem ->
          Buf.skip buf rem;
          finalise acc buf (Ok (tar, None, None))
      | Ok (tar, Some (`Header hdr), _) when is_enough buf hdr ->
          let len = Int64.to_int hdr.Tar.Header.file_size in
          (* Format.eprintf "[+] %s (%d byte(s))\n%!" hdr.Tar.Header.file_name len; *)
          let contents = Result.get_ok (Buf.get buf len) in
          let acc = k.push acc (hdr, contents) in
          if k.full acc then k.stop acc
          else
            let rem = Tar.Header.compute_zero_padding_length hdr in
            finalise acc buf (Ok (tar, Some (`Skip rem), None))
      | Ok (tar, None, _) when Buf.max buf >= Tar.Header.length ->
          let data = Result.get_ok (Buf.get buf Tar.Header.length) in
          finalise acc buf (Tar.decode tar data)
      | _ -> k.stop acc
    in
    let init () =
      let tar = Tar.decode_state ()
      and buf = Buf.create 0x7ff
      and acc = k.init () in
      (acc, buf, Ok (tar, None, None))
    and push (acc, buf, state) str = Buf.put buf str; unfold acc buf state
    and full (acc, _, state) =
      match state with Error (`Eof | `Fatal _) -> true | _ -> k.full acc
    and stop (acc, buf, state) =
      if k.full acc then k.stop acc else finalise acc buf state
    in
    Sink { init; push; full; stop }
  in
  { flow }
