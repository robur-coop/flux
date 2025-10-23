let daemon () =
  let q = Flux.Bqueue.(create infinite 0x7ff) in
  let rec go () =
    let `Are_you_alive = Flux.Bqueue.get q in
    print_endline "I'm alive"; go ()
  in
  (Miou.call go, q)

let ( let@ ) finally fn = Fun.protect ~finally fn

let () =
  Miou_unix.run ~domains:1 @@ fun () ->
  let daemon, q = daemon () in
  let@ () = fun () -> Miou.cancel daemon in
  let are_you_alive _ = Flux.Bqueue.put q `Are_you_alive in
  let behavior = Sys.Signal_handle are_you_alive in
  ignore (Miou.sys_signal Sys.sigint behavior);
  while true do
    Miou_unix.sleep 1.
  done
