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
  let open Flux in
  let from =
    Source.with_task ~size:0x7ff @@ fun q ->
    let lst = List.init 10 Fun.id in
    let fn = Bqueue.put q in
    List.iter fn lst
  in
  let stream = Stream.from from in
  let lst = Stream.into Sink.list stream in
  Alcotest.(check (list int)) "[0..10[" lst (List.init 10 Fun.id)

let () =
  Miou_unix.run @@ fun () ->
  Alcotest.run "test"
    [
      ("basics", [ basic00; basic01; basic02; basic03; basic04; basic05 ])
    ; ("miou", [ miou00; miou01 ])
    ]
