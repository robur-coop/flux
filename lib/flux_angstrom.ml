module Ke = struct
  type t = {
      mutable rd: int
    ; mutable wr: int
    ; mutable ln: int
    ; mutable bstr: Bstr.t
  }

  (* NOTE(dinosaure): [ln] must be a power of two. *)
  let unsafe_create ln = { rd= 0; wr= 0; ln; bstr= Bstr.create ln }
  let mask t v = v land (t.ln - 1)
  let shift t len = t.rd <- t.rd + len
  let available t = t.ln - (t.wr - t.rd)
  let length t = t.wr - t.rd

  let compress t =
    let len = length t in
    let mask = mask t t.rd in
    let pre = t.ln - mask in
    let rem = len - pre in
    if rem > 0 then
      if available t >= pre then begin
        Bstr.blit t.bstr ~src_off:0 t.bstr ~dst_off:pre ~len:rem;
        Bstr.blit t.bstr ~src_off:mask t.bstr ~dst_off:0 ~len:pre
      end
      else begin
        let tmp = Bytes.create pre in
        Bstr.blit_to_bytes t.bstr ~src_off:mask tmp ~dst_off:0 ~len:pre;
        Bstr.blit t.bstr ~src_off:0 t.bstr ~dst_off:pre ~len:rem;
        Bstr.blit_from_bytes tmp ~src_off:0 t.bstr ~dst_off:0 ~len:pre
      end
    else Bstr.blit t.bstr ~src_off:mask t.bstr ~dst_off:0 ~len;
    t.rd <- 0;
    t.wr <- len

  let to_power_of_two v =
    let v = ref (pred v) in
    v := !v lor (!v lsr 1);
    v := !v lor (!v lsr 2);
    v := !v lor (!v lsr 4);
    v := !v lor (!v lsr 8);
    v := !v lor (!v lsr 16);
    succ !v

  let grow t want =
    let ln = to_power_of_two (Int.max 1 (Int.max want (length t))) in
    if ln <> Bstr.length t.bstr then begin
      let dst = Bstr.create ln in
      let length = length t in
      let mask = mask t t.rd in
      let pre = t.ln - mask in
      let rem = length - pre in
      if rem > 0 then begin
        Bstr.blit t.bstr ~src_off:mask dst ~dst_off:0 ~len:pre;
        Bstr.blit t.bstr ~src_off:0 dst ~dst_off:pre ~len:rem
      end
      else Bstr.blit t.bstr ~src_off:mask dst ~dst_off:0 ~len:length;
      t.bstr <- dst;
      t.wr <- length;
      t.ln <- ln;
      t.rd <- 0
    end

  let push t str =
    let len = String.length str in
    if available t < len then grow t (len + length t);
    let mask = mask t t.wr in
    let pre = t.ln - mask in
    let rem = len - pre in
    if rem > 0 then begin
      Bstr.blit_from_string str ~src_off:0 t.bstr ~dst_off:mask ~len:pre;
      Bstr.blit_from_string str ~src_off:pre t.bstr ~dst_off:0 ~len:rem
    end
    else Bstr.blit_from_string str ~src_off:0 t.bstr ~dst_off:mask ~len;
    t.wr <- t.wr + len

  let peek t =
    match length t with
    | 0 -> []
    | len ->
        let mask = mask t t.rd in
        let pre = t.ln - mask in
        let rem = len - pre in
        if rem > 0 then
          let a = Bstr.sub t.bstr ~off:mask ~len:pre in
          let b = Bstr.sub t.bstr ~off:0 ~len:rem in
          [ a; b ]
        else [ Bstr.sub t.bstr ~off:mask ~len ]
end

let push ke str = function
  | Angstrom.Unbuffered.Done _ as state -> state
  | Fail _ as state -> state
  | Partial { committed; continue } ->
      Ke.shift ke committed;
      if committed = 0 then Ke.compress ke;
      Ke.push ke str;
      let chunks = Ke.peek ke in
      let chunk = List.hd chunks in
      continue chunk ~off:0 ~len:(Bstr.length chunk) Incomplete

let close ke = function
  | Angstrom.Unbuffered.Done _ as state -> state
  | Fail _ as state -> state
  | Partial { committed= _; continue } when Ke.length ke = 0 ->
      continue Bstr.empty ~off:0 ~len:0 Complete
  | Partial { committed; continue } -> begin
      Ke.shift ke committed;
      Ke.compress ke;
      match Ke.peek ke with
      | [] -> continue Bstr.empty ~off:0 ~len:0 Complete
      | chunk :: _ -> continue chunk ~off:0 ~len:(Bstr.length chunk) Complete
    end

let parser p =
  let open Angstrom.Unbuffered in
  let init () = (Ke.unsafe_create 0x10000, parse p)
  and push (ke, state) = function
    | "" -> (ke, state)
    | str ->
        let state = push ke str state in
        (ke, state)
  and full (_, state) =
    match state with Done _ | Fail _ -> true | Partial _ -> false
  and stop (ke, state) =
    match close ke state with
    | Done (_, v) -> Ok v
    | Fail (committed, _, _) ->
        Ke.shift ke committed;
        Ke.compress ke;
        begin match Ke.peek ke with
        | [] -> Error None
        | chunk :: _ -> Error (Some (Bstr.to_string chunk))
        end
    | Partial _ -> assert false
  in
  Flux.Sink { init; push; full; stop }
