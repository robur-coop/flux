let random filename q =
  let ic = open_in filename in
  let icr = Miou.Ownership.create ~finally:close_in ic in
  let qr = Miou.Ownership.create ~finally:Flux.Bqueue.halt q in
  Miou.Ownership.own icr;
  Miou.Ownership.own qr;
  let buf = Bytes.create 0x7ff in
  let rec go () =
    match input ic buf 0 (Bytes.length buf) with
    | 0 | (exception End_of_file) ->
        Miou.Ownership.release icr; Miou.Ownership.release qr
    | len ->
        let str = Bytes.sub_string buf 0 len in
        Flux.Bqueue.put q str; go ()
  in
  Miou.call ~give:[ icr; qr ] go

let entropy q =
  let freqs = Array.make 256 0 in
  let rec go iter () =
    match Flux.Bqueue.get q with
    | None ->
        let total = Array.fold_left Int.add 0 freqs in
        let total = Float.of_int total in
        let entropy = ref 0. in
        for byte = 0 to 255 do
          match freqs.(byte) with
          | 0 -> ()
          | n ->
              let count = Float.of_int n in
              let p = count /. total in
              if p >= 0. then entropy := !entropy -. (p *. Float.log2 p)
        done;
        (!entropy, iter)
    | Some str ->
        let fn chr =
          let code = Char.code chr in
          freqs.(code) <- freqs.(code) + 1
        in
        String.iter fn str;
        go (succ iter) ()
  in
  Miou.async (go 0)

let () =
  Miou_unix.run ~domains:1 @@ fun () ->
  let q = Flux.Bqueue.(create with_close_and_halt 0x7ff) in
  let prm0 = random Sys.argv.(1) q in
  let prm1 = entropy q in
  Miou_unix.sleep 1.;
  Miou.cancel prm0;
  let entropy, iter = Miou.await_exn prm1 in
  Format.printf "Entropy %f (%d iteration(s))\n%!" entropy iter
