type cfg = {
    level: int
  ; mtime: int32
  ; os: Gz.os
  ; q: De.Queue.t
  ; w: De.Lz77.window
}

let now = Fun.compose Int32.of_float Sys.time

let _unsafe_ctz n =
  let t = ref 1 and r = ref 0 in
  while n land !t == 0 do
    t := !t lsl 1;
    incr r
  done;
  !r

let _unsafe_power_of_two x = x land (x - 1) == 0 && x != 0

let config ?(mtime = now ()) ?(level = 4) ?(size_of_queue = 0x1000)
    ?(size_of_window = 0x8000) ?(os = Gz.Unix) () =
  if size_of_queue < 0 then
    invalid_arg "Flux_gz.config: invalid negative number for the size of queue";
  if not (_unsafe_power_of_two size_of_queue) then
    invalid_arg "Flux_gz.config: the size of queue must be a power of two";
  if size_of_window < 0 then
    invalid_arg "Flux_gz.config: invalid negative number for the size of window";
  if not (_unsafe_power_of_two size_of_window) then
    invalid_arg "Flux_gz.config: the of size of window must be a power of two";
  if _unsafe_ctz size_of_window > 15 then
    invalid_arg "Flux_gz.config: too big size of window";
  let q = De.Queue.create size_of_queue in
  let w = De.Lz77.make_window ~bits:(_unsafe_ctz size_of_window) in
  { level; mtime; os; q; w }

let deflate cfg =
  let open Flux in
  let flow (Sink k) =
    let rec until_await encoder o acc =
      assert (not (k.full acc));
      match Gz.Def.encode encoder with
      | `Await encoder -> `Continue (encoder, o, acc)
      | `Flush encoder ->
          let len = Bstr.length o - Gz.Def.dst_rem encoder in
          let encoder = Gz.Def.dst encoder o 0 (Bstr.length o) in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          if k.full acc then `Stop acc else until_await encoder o acc
      | `End _ -> assert false
    in
    let rec until_end encoder o acc =
      assert (not (k.full acc));
      match Gz.Def.encode encoder with
      | `Flush encoder ->
          let len = Bstr.length o - Gz.Def.dst_rem encoder in
          let encoder = Gz.Def.dst encoder o 0 (Bstr.length o) in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          if k.full acc then acc else until_end encoder o acc
      | `End encoder ->
          let len = Bstr.length o - Gz.Def.dst_rem encoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          k.push acc str
      | `Await _ -> assert false
    in
    let init () =
      let w = cfg.w and q = cfg.q and level = cfg.level and mtime = cfg.mtime in
      let encoder = Gz.Def.encoder `Manual `Manual ~mtime cfg.os ~q ~w ~level in
      let o = Bstr.create 0x7ff in
      let encoder = Gz.Def.dst encoder o 0 0x7ff in
      let acc = k.init () in
      `Continue (encoder, o, acc)
    in
    let push state bstr =
      match (state, Bstr.length bstr) with
      | _, 0 | `Stop _, _ -> state
      | `Continue (encoder, o, acc), _ ->
          let encoder = Gz.Def.src encoder bstr 0 (Bstr.length bstr) in
          until_await encoder o acc
    in
    let full = function `Continue (_, _, acc) | `Stop acc -> k.full acc in
    let stop = function
      | `Stop acc -> k.stop acc
      | `Continue (encoder, o, acc) when not (k.full acc) ->
          let encoder = Gz.Def.src encoder Bstr.empty 0 0 in
          let acc = until_end encoder o acc in
          k.stop acc
      | `Continue (_, _, acc) -> k.stop acc
    in
    Sink { init; push; full; stop }
  in
  { flow }

let inflate =
  let open Flux in
  let flow (Sink k) =
    let rec until_await_or_end decoder o acc =
      assert (not (k.full acc));
      match Gz.Inf.decode decoder with
      | `Await decoder -> `Continue (decoder, o, acc)
      | `Flush decoder ->
          let len = Bstr.length o - Gz.Inf.dst_rem decoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          let decoder = Gz.Inf.flush decoder in
          if k.full acc then `Stop acc else until_await_or_end decoder o acc
      | `Malformed _ -> `Stop acc
      | `End decoder ->
          let len = Bstr.length o - Gz.Inf.dst_rem decoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          `Stop acc
    in
    let rec until_end decoder o acc =
      assert (not (k.full acc));
      match Gz.Inf.decode decoder with
      | `Await _ -> acc
      | `Flush decoder ->
          let len = Bstr.length o - Gz.Inf.dst_rem decoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          let decoder = Gz.Inf.flush decoder in
          if k.full acc then acc else until_end decoder o acc
      | `Malformed _ -> acc
      | `End decoder ->
          let len = Bstr.length o - Gz.Inf.dst_rem decoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          k.push acc str
    in
    let init () =
      let o = Bstr.create 0x7ff in
      let decoder = Gz.Inf.decoder `Manual ~o in
      let acc = k.init () in
      `Continue (decoder, o, acc)
    in
    let push state bstr =
      match (state, Bstr.length bstr) with
      | _, 0 | `Stop _, _ -> state
      | `Continue (decoder, o, acc), _ ->
          let decoder = Gz.Inf.src decoder bstr 0 (Bstr.length bstr) in
          until_await_or_end decoder o acc
    in
    let full = function `Continue (_, _, acc) | `Stop acc -> k.full acc in
    let stop = function
      | `Stop acc -> k.stop acc
      | `Continue (decoder, o, acc) when not (k.full acc) ->
          let decoder = Gz.Inf.src decoder Bstr.empty 0 0 in
          let acc = until_end decoder o acc in
          k.stop acc
      | `Continue (_, _, acc) -> k.stop acc
    in
    Sink { init; push; full; stop }
  in
  { flow }
