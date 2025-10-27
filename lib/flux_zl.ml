type cfg = { level: int; q: De.Queue.t; w: De.Lz77.window }

let _unsafe_ctz n =
  let t = ref 1 and r = ref 0 in
  while n land !t == 0 do
    t := !t lsl 1;
    incr r
  done;
  !r

let _unsafe_power_of_two x = x land (x - 1) == 0 && x != 0

let config ?(level = 4) ?(size_of_queue = 0x1000) ?(size_of_window = 0x8000) ()
    =
  if size_of_queue < 0 then
    invalid_arg "Flux_zl.config: invalid negative number for the size of queue";
  if not (_unsafe_power_of_two size_of_queue) then
    invalid_arg "Flux_zl.config: the size of queue must be a power of two";
  if size_of_window < 0 then
    invalid_arg "Flux_zl.config: invalid negative number for the size of window";
  if not (_unsafe_power_of_two size_of_window) then
    invalid_arg "Flux_zl.config: the of size of window must be a power of two";
  if _unsafe_ctz size_of_window > 15 then
    invalid_arg "Flux_zl.config: too big size of window";
  let q = De.Queue.create size_of_queue in
  let w = De.Lz77.make_window ~bits:(_unsafe_ctz size_of_window) in
  { level; q; w }

let deflate cfg =
  let open Flux in
  let flow (Sink k) =
    let rec until_await encoder o acc =
      assert (not (k.full acc));
      match Zl.Def.encode encoder with
      | `Await encoder -> `Continue (encoder, o, acc)
      | `Flush encoder ->
          let len = Bstr.length o - Zl.Def.dst_rem encoder in
          let encoder = Zl.Def.dst encoder o 0 (Bstr.length o) in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          if k.full acc then `Stop acc else until_await encoder o acc
      | `End _ -> assert false
    in
    let rec until_end encoder o acc =
      assert (not (k.full acc));
      match Zl.Def.encode encoder with
      | `Flush encoder ->
          let len = Bstr.length o - Zl.Def.dst_rem encoder in
          let encoder = Zl.Def.dst encoder o 0 (Bstr.length o) in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          if k.full acc then acc else until_end encoder o acc
      | `End encoder ->
          let len = Bstr.length o - Zl.Def.dst_rem encoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          k.push acc str
      | `Await _ -> assert false
    in
    let init () =
      let w = cfg.w and q = cfg.q and level = cfg.level in
      let encoder = Zl.Def.encoder ~q ~w ~level `Manual `Manual in
      let o = Bstr.create 0x7ff in
      let encoder = Zl.Def.dst encoder o 0 0x7ff in
      let acc = k.init () in
      `Continue (encoder, o, acc)
    in
    let push state bstr =
      match (state, Bstr.length bstr) with
      | _, 0 | `Stop _, _ -> state
      | `Continue (encoder, o, acc), _ ->
          let encoder = Zl.Def.src encoder bstr 0 (Bstr.length bstr) in
          until_await encoder o acc
    in
    let full = function `Continue (_, _, acc) | `Stop acc -> k.full acc in
    let stop = function
      | `Stop acc -> k.stop acc
      | `Continue (encoder, o, acc) when not (k.full acc) ->
          let encoder = Zl.Def.src encoder Bstr.empty 0 0 in
          let acc = until_end encoder o acc in
          k.stop acc
      | `Continue (_, _, acc) -> k.stop acc
    in
    Sink { init; push; full; stop }
  in
  { flow }

let inflate =
  let allocate bits = De.make_window ~bits in
  let open Flux in
  let flow (Sink k) =
    let rec until_await_or_end decoder o acc =
      assert (not (k.full acc));
      match Zl.Inf.decode decoder with
      | `Await decoder -> `Continue (decoder, o, acc)
      | `Flush decoder ->
          let len = Bstr.length o - Zl.Inf.dst_rem decoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          let decoder = Zl.Inf.flush decoder in
          if k.full acc then `Stop acc else until_await_or_end decoder o acc
      | `Malformed _ -> `Stop acc
      | `End decoder ->
          let len = Bstr.length o - Zl.Inf.dst_rem decoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          `Stop acc
    in
    let rec until_end decoder o acc =
      assert (not (k.full acc));
      match Zl.Inf.decode decoder with
      | `Await _ -> acc
      | `Flush decoder ->
          let len = Bstr.length o - Zl.Inf.dst_rem decoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          let decoder = Zl.Inf.flush decoder in
          if k.full acc then acc else until_end decoder o acc
      | `Malformed _ -> acc
      | `End decoder ->
          let len = Bstr.length o - Zl.Inf.dst_rem decoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          k.push acc str
    in
    let init () =
      let o = Bstr.create 0x7ff in
      let decoder = Zl.Inf.decoder `Manual ~o ~allocate in
      let acc = k.init () in
      `Continue (decoder, o, acc)
    in
    let push state bstr =
      match (state, Bstr.length bstr) with
      | _, 0 | `Stop _, _ -> state
      | `Continue (decoder, o, acc), _ ->
          let decoder = Zl.Inf.src decoder bstr 0 (Bstr.length bstr) in
          until_await_or_end decoder o acc
    in
    let full = function `Continue (_, _, acc) | `Stop acc -> k.full acc in
    let stop = function
      | `Stop acc -> k.stop acc
      | `Continue (decoder, o, acc) when not (k.full acc) ->
          let decoder = Zl.Inf.src decoder Bstr.empty 0 0 in
          let acc = until_end decoder o acc in
          k.stop acc
      | `Continue (_, _, acc) -> k.stop acc
    in
    Sink { init; push; full; stop }
  in
  { flow }
