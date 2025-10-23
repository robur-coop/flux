let consumer q max =
  let counter = ref 0 in
  Format.printf "%d/%d%!" !counter max;
  let rec go () =
    match Flux.Bqueue.get q with
    | None -> Format.printf "\n%!"
    | Some bytes ->
        counter := !counter + bytes;
        Format.printf "\r%d/%d%!" !counter max;
        go ()
  in
  Miou.async go

let producer q ic =
  let buf = Bytes.create 0x7ff in
  let rec go () =
    match input ic buf 0 (Bytes.length buf) with
    | 0 | (exception End_of_file) -> Flux.Bqueue.close q
    | len -> Flux.Bqueue.put q len; go ()
  in
  Miou.call go

let ( let@ ) finally fn = Fun.protect ~finally fn

let () =
  Miou_unix.run ~domains:1 @@ fun () ->
  let q = Flux.Bqueue.(create with_close 0x7ff) in
  let ic = open_in Sys.argv.(1) in
  let@ () = fun () -> close_in ic in
  let max = in_channel_length ic in
  let prm0 = consumer q max and prm1 = producer q ic in
  Miou.await_all [ prm0; prm1 ]
  |> List.iter (function Ok () -> () | Error exn -> raise exn)
