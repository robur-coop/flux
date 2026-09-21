let basic00 =
  Alcotest.test_case "basic00" `Quick @@ fun () ->
  let open Flux in
  let from = Source.list [ 0; 1; 2; 3; 4; 5 ] in
  let lst, _ = Stream.run ~from ~via:Flow.identity ~into:Sink.list in
  Alcotest.(check (list int)) "list -> list" lst [ 0; 1; 2; 3; 4; 5 ];
  let into = Sink.fold Int.add 0 in
  let sum, _ = Stream.run ~from ~via:Flow.identity ~into in
  Alcotest.(check int) "list -> int" sum 15;
  let into = Sink.buffer 3 in
  let arr, _ = Stream.run ~from ~via:Flow.identity ~into in
  Alcotest.(check (array int)) "list -> array" arr [| 0; 1; 2 |]

let basic01 =
  Alcotest.test_case "basic01" `Quick @@ fun () ->
  let open Flux in
  let value = Stream.into (Sink.fill 42) Stream.empty in
  Alcotest.(check int) "empty -> 42" value 42;
  let value = Stream.into (Sink.fill 42) Stream.(range 0 10) in
  Alcotest.(check int) "[0..10[ -> 42" value 42;
  let value = Stream.into (Sink.fill 42) (Stream.repeat 0) in
  Alcotest.(check int) "infinite -> 42" value 42

let basic02 =
  Alcotest.test_case "basic02" `Quick @@ fun () ->
  let open Flux in
  let value = Stream.into Sink.full Stream.empty in
  Alcotest.(check unit) "full -> unit" value ();
  let value = Stream.into Sink.full Stream.(range 0 10) in
  Alcotest.(check unit) "full -> unit" value ();
  let value = Stream.into Sink.full (Stream.repeat 0) in
  Alcotest.(check unit) "full -> unit" value ()

let basic03 =
  Alcotest.test_case "basic03" `Quick @@ fun () ->
  let open Flux in
  let len = Stream.into Sink.length Stream.empty in
  Alcotest.(check int) "empty -> 0" len 0;
  let len = Stream.into Sink.length Stream.(range 0 10) in
  Alcotest.(check int) "[0..10[ -> 10" len 10

let basic04 =
  Alcotest.test_case "basic04" `Quick @@ fun () ->
  let open Flux in
  let n = ref 0 in
  let fn _ = incr n in
  let stream = Stream.(via (Flow.tap fn) (range 0 10)) in
  let () = Stream.into Sink.drain stream in
  Alcotest.(check int) "[0..10[ -> unit" !n 10

let basic05 =
  Alcotest.test_case "basic05" `Quick @@ fun () ->
  let open Flux in
  let sum = Sink.fold Int.add 0 in
  let res = Stream.into sum Stream.empty in
  Alcotest.(check int) "empty -> 0" res 0;
  let res = Stream.into sum Stream.(range 0 10) in
  Alcotest.(check int) "[0..10[ -> 45" res 45

let miou00 =
  Alcotest.test_case "miou00" `Quick @@ fun () ->
  let open Flux in
  let from =
    Source.with_task ~size:0x7ff @@ fun q ->
    let lst = List.init 10 Fun.id in
    let fn = Bqueue.put q in
    List.iter fn lst; Bqueue.close q
  in
  let stream = Stream.from from in
  let lst = Stream.into Sink.list stream in
  Alcotest.(check (list int)) "[0..10[" lst (List.init 10 Fun.id)

let miou01 =
  Alcotest.test_case "miou01" `Quick @@ fun () ->
  let exception Foo in
  let open Flux in
  let from =
    Source.with_task ~size:0x7ff @@ fun q ->
    let lst = List.init 10 Fun.id in
    let fn = Bqueue.put q in
    List.iter fn lst; raise Foo
  in
  let stream = Stream.from from in
  try
    ignore (Stream.into Sink.list stream);
    Alcotest.failf "The task should not terminate correctly"
  with Foo -> Alcotest.(check pass) "foo" () ()

let miou02 =
  Alcotest.test_case "miou02" `Quick @@ fun () ->
  let open Flux in
  (* An infinite queue and we would like to allocate, consume some,
     and properly clean-up everything. *)
  let v = Atomic.make false in
  let from =
    Source.with_task ~size:0x7ff @@ fun q ->
    let finally () = assert (Atomic.exchange v true = false) in
    let r = Miou.Ownership.create ~finally () in
    Miou.Ownership.own r;
    while true do
      Flux.Bqueue.put q ()
    done;
    Miou.Ownership.release r
  in
  let stream = Stream.from from in
  let _ = Stream.into (Sink.buffer 2) stream in
  Alcotest.(check bool) "resource" (Atomic.get v) true

let formatter01 =
  Alcotest.test_case "formatter01" `Quick @@ fun () ->
  let s = "Hello, World!" in
  let src =
    Flux.Source.with_buffered_formatter ~size:16 ~buffer_size:1024 @@ fun ppf ->
    Format.pp_print_string ppf s
  in
  let called = ref false in
  Flux.Source.each
    (fun s' ->
      called := true;
      Alcotest.(check string) "." s s')
    src;
  if not !called then Alcotest.fail "nothing was flushed"

exception Timeout

let with_timeout ?(sec = 10.) fn =
  let timeout () = Miou_unix.sleep sec; raise Timeout in
  match Miou.await_first [ Miou.async timeout; Miou.async fn ] with
  | Ok value -> value
  | Error Timeout -> Alcotest.failf "a task was never woken up"
  | Error exn -> raise exn

(* NOTE(dinosaure): This is a very subtle case. As it is an asynchronous task,
   there are therefore two execution flows:
   1) the first ([prm]) involves [await_exn ivar0], [try_return] and [put]
   2) the second involves [try_return], [await_exn ivar1], [close] and
      [await_exn]

   The main idea is that we know that [prm] executes (and performs
   [try_return]) whilst the main thread is waiting ([await_exn ivar1]). In this
   specific case, [try_return ivar1] should then wake up [await_exn ivar1] and,
   in the Miou model, attempt to execute the rest of the sequence, including
   our [close].

   If [close] does not have any effect (which is normally the case), we should
   then be waiting for the promise [prm], and this should in turn execute and
   attempt [put]. Except that we have just called [close], so we should now
   have an [Invalid_argument] error (since we cannot add data to a closed
   queue).

   This example shows that [close] is atomic from Miou's perspective and
   nothing else executes at the same time. This atomicity should also apply to
   domains (we could replace [Miou.async] with [Miou.call]); there is a race
   condition between the [Atomic.set m.close] of our queue and the [put]
   function. On this point, I am less confident; [put] eventually reaches the
   [Atomic.get m.close] after several steps (which includes a
   [Miou.Mutex.protect]), meaning that this code should also be safe with
   [Miou.call], but this is based on implementation details.

   In other words, this code **is** essentially correct with [Miou.async] and
   **may** be correct with [Miou.call]. *)

let bqueue00 =
  Alcotest.test_case "bqueue00" `Quick @@ fun () ->
  with_timeout @@ fun () ->
  let q = Flux.Bqueue.(create with_close) 2 in
  Flux.Bqueue.put q 0;
  let ivar0 = Miou.Computation.create () in
  let ivar1 = Miou.Computation.create () in
  let producer =
    Miou.async @@ fun () ->
    Miou.Computation.await_exn ivar0;
    ignore (Miou.Computation.try_return ivar1 ());
    match Flux.Bqueue.put q 1 with
    | () -> `Put
    | exception Invalid_argument _ -> `Closed
  in
  ignore (Miou.Computation.try_return ivar0 ());
  Miou.Computation.await_exn ivar1;
  Flux.Bqueue.close q;
  Alcotest.(check bool) "put raised" true (Miou.await_exn producer = `Closed)

let bqueue01 =
  Alcotest.test_case "bqueue01" `Quick @@ fun () ->
  with_timeout @@ fun () ->
  let q = Flux.Bqueue.(create with_close) 4 in
  let waiting = Atomic.make 0 in
  let ivar = Miou.Computation.create () in
  let consumer () =
    ignore (Miou.Computation.try_return ivar ());
    Atomic.incr waiting;
    Flux.Bqueue.get q
  in
  let prms = List.init 4 (fun _ -> Miou.call consumer) in
  while Atomic.get waiting < 4 do
    Miou.yield ()
  done;
  Miou.Computation.await_exn ivar;
  (* NOTE(dinosaure): here, we broadcast. *)
  Flux.Bqueue.close q;
  let fn prm = Alcotest.(check (option int)) "none" None (Miou.await_exn prm) in
  List.iter fn prms

let bqueue02 =
  Alcotest.test_case "bqueue02" `Quick @@ fun () ->
  with_timeout @@ fun () ->
  let full = Flux.Bqueue.(create with_close_and_halt) 2 in
  let empty = Flux.Bqueue.(create with_close_and_halt) 2 in
  Flux.Bqueue.put full 0;
  let ivar = Miou.Computation.create () in
  let producer =
    Miou.async @@ fun () ->
    Miou.Computation.await_exn ivar;
    match Flux.Bqueue.put full 1 with
    | () -> false
    | exception Invalid_argument _ -> true
  in
  let consumer = Miou.call @@ fun () -> Flux.Bqueue.get empty in
  ignore (Miou.Computation.try_return ivar ());
  Flux.Bqueue.halt full;
  Flux.Bqueue.halt empty;
  Alcotest.(check bool) "put raised" true (Miou.await_exn producer);
  Alcotest.(check (option int)) "get" None (Miou.await_exn consumer)

let bqueue03 =
  Alcotest.test_case "bqueue03" `Quick @@ fun () ->
  with_timeout @@ fun () ->
  let q = Flux.Bqueue.(create with_close) 4 in
  let filled = Atomic.make false in
  let producer =
    Miou.call @@ fun () ->
    let finally ~cancelled:_ = Flux.Bqueue.close q in
    let on_cancellation = ignore in
    Miou.protect ~on_cancellation ~finally @@ fun () ->
    Flux.Bqueue.put q 42;
    Atomic.set filled true;
    while true do
      Miou.yield ()
    done
  in
  let consumer =
    Miou.call @@ fun () ->
    let rec go acc =
      match Flux.Bqueue.get q with
      | None -> List.rev acc
      | Some v -> go (v :: acc)
    in
    go []
  in
  while not (Atomic.get filled) do
    Miou.yield ()
  done;
  (* NOTE(dinosaure): [cancel] should trigger [close]. *)
  Miou.cancel producer;
  Alcotest.(check (list int))
    "the consumer ends" [ 42 ] (Miou.await_exn consumer)

let bqueue04 =
  Alcotest.test_case "bqueue04" `Quick @@ fun () ->
  with_timeout @@ fun () ->
  let q = Flux.Bqueue.(create with_close) 4 in
  let filled = Atomic.make false in
  let producer =
    Miou.call @@ fun () ->
    let finally = Flux.Bqueue.close in
    let res = Miou.Ownership.create ~finally q in
    Miou.Ownership.own res;
    Flux.Bqueue.put q 42;
    Atomic.set filled true;
    while true do
      Miou.yield ()
    done;
    Miou.Ownership.release res
  in
  let consumer =
    Miou.call @@ fun () ->
    let rec go acc =
      match Flux.Bqueue.get q with
      | None -> List.rev acc
      | Some v -> go (v :: acc)
    in
    go []
  in
  while not (Atomic.get filled) do
    Miou.yield ()
  done;
  (* NOTE(dinosaure): [cancel] should trigger [close]. *)
  Miou.cancel producer;
  Alcotest.(check (list int))
    "the consumer ends" [ 42 ] (Miou.await_exn consumer)

(* NOTE(dinosaure): This test checks whether closing a queue whilst consumers
   and producers are still active ensures that all tasks stop _at the same
   time_. In other words, the producer should not produce more than the
   consumer has consumed (please note that this only works with [close]; the
   behaviour with [halt] is somewhat more unpredictable). *)

let bqueue05 =
  Alcotest.test_case "bqueue05" `Slow @@ fun () ->
  with_timeout ~sec:120. @@ fun () ->
  let rounds = 2000 in
  for round = 1 to rounds do
    let q = Flux.Bqueue.(create with_close) 3 in
    let producer () =
      let rec go n =
        match Flux.Bqueue.put q n with
        | () -> go (n + 1)
        | exception Invalid_argument _ -> n
      in
      go 0
    in
    let consumer () =
      let rec go n =
        match Flux.Bqueue.get q with None -> n | Some _ -> go (n + 1)
      in
      go 0
    in
    let producers = List.init 2 (fun _ -> Miou.call producer) in
    let consumers = List.init 2 (fun _ -> Miou.call consumer) in
    let closer =
      Miou.call @@ fun () ->
      for _ = 1 to round mod 50 do
        Miou.yield ()
      done;
      Flux.Bqueue.close q
    in
    Miou.await_exn closer;
    let sum prms =
      List.fold_left (fun acc prm -> acc + Miou.await_exn prm) 0 prms
    in
    let put = sum producers and got = sum consumers in
    if put <> got then
      Alcotest.failf "round %d: %d put but %d got" round put got
  done

let () =
  Miou_unix.run ~domains:4 @@ fun () ->
  Alcotest.run "test"
    [
      ("basics", [ basic00; basic01; basic02; basic03; basic04; basic05 ])
    ; ("formatter", [ formatter01 ]); ("miou", [ miou00; miou01; miou02 ])
    ; ("bqueue", [ bqueue00; bqueue01; bqueue02; bqueue03; bqueue04; bqueue05 ])
    ]
