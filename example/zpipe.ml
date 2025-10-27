let to_bigstring =
  let flow (Flux.Sink k) =
    let init () = (k.init (), Bstr.create 0x7ff, 0)
    and push (acc, bstr, dst_off) str =
      let rec go acc src_off dst_off =
        if src_off = String.length str then (acc, bstr, dst_off)
        else
          let rem_bstr = Bstr.length bstr - dst_off
          and rem_str = String.length str - src_off in
          let len = Int.min rem_bstr rem_str in
          Bstr.blit_from_string str ~src_off bstr ~dst_off ~len;
          if dst_off + len = Bstr.length bstr then
            let acc = k.push acc bstr in
            if k.full acc then (acc, bstr, 0) else go acc (src_off + len) 0
          else (acc, bstr, dst_off + len)
      in
      go acc 0 dst_off
    and full (acc, _, _) = k.full acc
    and stop (acc, bstr, dst_off) =
      if dst_off > 0 && not (k.full acc) then
        let bstr = Bstr.sub bstr ~off:0 ~len:dst_off in
        k.stop (k.push acc bstr)
      else k.stop acc
    in
    Flux.Sink { init; push; full; stop }
  in
  { Flux.flow }

let () =
  Miou_unix.run @@ fun () ->
  let zl =
    match Sys.argv with
    | [| _; "-d" |] -> Flux_zl.(deflate (config ()))
    | _ -> Flux_zl.inflate
  in
  let via = Flux.Flow.(to_bigstring << zl) in
  let from = Flux.Source.in_channel stdin in
  let into = Flux.Sink.out_channel stdout in
  let (), leftover = Flux.Stream.run ~from ~via ~into in
  Option.iter Flux.Source.dispose leftover
