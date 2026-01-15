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

let deflate ~cfg =
  let open Flux in
  let flow (Sink k) =
    let rec emit cb encoder lz77 o acc = function
      | `Partial ->
          assert (not (k.full acc));
          let len = Bstr.length o - De.Def.dst_rem encoder in
          let str = Bstr.sub_string o ~off:0 ~len in
          let acc = k.push acc str in
          De.Def.dst encoder o 0 (Bstr.length o);
          if k.full acc then cb encoder lz77 o (`Stop acc)
          else emit cb encoder lz77 o acc (De.Def.encode encoder `Await)
      | `Ok -> cb encoder lz77 o (`Continue acc)
      | `Block ->
          let literals = De.Lz77.literals lz77 in
          let distances = De.Lz77.distances lz77 in
          let dynamic = De.Def.dynamic_of_frequencies ~literals ~distances in
          let kind = De.Def.Dynamic dynamic in
          emit cb encoder lz77 o acc
            (De.Def.encode encoder (`Block { De.Def.kind; last= false }))
    in
    let rec compress encoder lz77 o acc =
      match De.Lz77.compress lz77 with
      | `Await -> `Continue (encoder, lz77, o, acc)
      | `Flush ->
          let literals = De.Lz77.literals lz77 in
          let distances = De.Lz77.distances lz77 in
          let dynamic = De.Def.dynamic_of_frequencies ~literals ~distances in
          let kind = De.Def.Dynamic dynamic in
          let cb encoder lz77 o = function
            | `Continue acc -> compress encoder lz77 o acc
            | `Stop acc -> `Stop acc
          in
          emit cb encoder lz77 o acc
            (De.Def.encode encoder (`Block { De.Def.kind; last= false }))
      | `End -> assert false
    in
    let rec remaining encoder lz77 o acc =
      match De.Lz77.compress lz77 with
      | `End ->
          assert (not (k.full acc));
          let kind = De.Def.Fixed in
          let cb _encoder _lz77 _o = function
            | `Continue acc | `Stop acc -> acc
          in
          emit cb encoder lz77 o acc
            (De.Def.encode encoder (`Block { De.Def.kind; last= true }))
      | `Flush ->
          let literals = De.Lz77.literals lz77 in
          let distances = De.Lz77.distances lz77 in
          let dynamic = De.Def.dynamic_of_frequencies ~literals ~distances in
          let kind = De.Def.Dynamic dynamic in
          let cb encoder lz77 o = function
            | `Continue acc -> remaining encoder lz77 o acc
            | `Stop acc -> acc
          in
          emit cb encoder lz77 o acc
            (De.Def.encode encoder (`Block { De.Def.kind; last= false }))
      | `Await -> assert false
    in
    let init () =
      let w = cfg.w and q = cfg.q and level = cfg.level in
      let lz77 = De.Lz77.state ~level ~w ~q `Manual in
      let encoder = De.Def.encoder `Manual ~q in
      let o = Bstr.create 0x7ff in
      De.Queue.reset q;
      De.Def.dst encoder o 0 0x7ff;
      let acc = k.init () in
      `Continue (encoder, lz77, o, acc)
    in
    let push state bstr =
      match (state, Bstr.length bstr) with
      | _, 0 | `Stop _, _ -> state
      | `Continue (encoder, lz77, o, acc), _ ->
          De.Lz77.src lz77 bstr 0 (Bstr.length bstr);
          compress encoder lz77 o acc
    in
    let full = function `Continue (_, _, _, acc) | `Stop acc -> k.full acc in
    let stop = function
      | `Stop acc -> k.stop acc
      | `Continue (encoder, lz77, o, acc) when not (k.full acc) ->
          De.Lz77.src lz77 Bstr.empty 0 0;
          let acc = remaining encoder lz77 o acc in
          k.stop acc
      | `Continue (_, _, _, acc) -> k.stop acc
    in
    Sink { init; push; full; stop }
  in
  { flow }
