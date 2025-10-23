(* Part of this code is based on the streaming project and
   Copyright (c) 2020 Rizo I. <rizo@odis.io>
   SPDX-License-Identifier: ISC
   Copyright (c) 2024 Romain Calascibetta <romain.calascibetta@gmail.com>
*)

let src = Logs.Src.create "flux"

module Log = (val Logs.src_log src : Logs.LOG)
module Bqueue = Bqueue

external reraise : exn -> 'a = "%reraise"

type +'a source =
  | Source : {
        init: unit -> 's
      ; pull: 's -> ('a * 's) option
      ; stop: 's -> unit
    }
      -> 'a source

module Source = struct
  let unfold seed pull =
    let init = Fun.const seed and stop = Fun.const () in
    Source { init; pull; stop }

  let list lst =
    let pull = function [] -> None | x :: r -> Some (x, r) in
    Source { init= Fun.const lst; pull; stop= ignore }

  let seq seq =
    let pull = Seq.uncons in
    Source { init= Fun.const seq; pull; stop= ignore }

  let array arr =
    let len = Array.length arr in
    let init = Fun.const 0
    and pull idx = if idx >= len then None else Some (arr.(idx), succ idx)
    and stop = Fun.const () in
    Source { init; pull; stop }

  let string str =
    let len = String.length str in
    let init = Fun.const 0
    and pull idx = if idx >= len then None else Some (str.[idx], succ idx)
    and stop = Fun.const () in
    Source { init; pull; stop }

  let queue q =
    let init = Fun.const q in
    let pull q = try Some (Queue.pop q, q) with Queue.Empty -> None
    and stop = Fun.const () in
    Source { init; pull; stop }

  let bqueue : type a.
      ?stop:[ `Ignore | `Halt | `Close ] -> (a, a option) Bqueue.t -> a source =
   fun ?stop:(behavior = `Ignore) q ->
    let init = Fun.const q
    and pull q = Option.map (fun a -> (a, q)) (Bqueue.get q)
    and stop =
      match behavior with
      | `Ignore -> ignore
      | `Halt -> Bqueue.halt
      | `Close -> Bqueue.close
    in
    Source { init; pull; stop }

  let map fn (Source src) =
    let pull s =
      let fn (v, s) = (fn v, s) in
      Option.map fn (src.pull s)
    in
    Source { src with pull }

  let empty =
    let init = Fun.const () and pull = Fun.const None and stop = Fun.const () in
    Source { init; pull; stop }

  let dispose (Source src) = src.stop (src.init ())

  let resource ~finally pull resource =
    let init () =
      let r = Miou.Ownership.create ~finally resource in
      Miou.Ownership.own r; (r, resource)
    (* NOTE(dinosaure): we probably need [Miou.Ownership.with_value] which can
       update the [resource] kept by Miou with a new one. Currently, we
       physically use the same [resource] for all [pull] and for
       [stop]/[finally]. *)
    and pull (r, resource) =
      match pull resource with
      | Some x -> Some (x, (r, resource))
      | None -> None
    and stop (r, _) = Miou.Ownership.release r in
    Source { init; pull; stop }

  type 'a task = ('a, 'a option) Bqueue.t -> unit

  let with_task ?(halt = false) ~size fn =
    let bqueue =
      match halt with
      | true -> Bqueue.(create with_close_and_halt size)
      | false -> Bqueue.(create with_close size)
    in
    let init () =
      let finally = if halt then Bqueue.halt else Bqueue.close in
      let res = Miou.Ownership.create ~finally bqueue in
      Miou.Ownership.own res;
      Miou.async ~give:[ res ] @@ fun () ->
      fn bqueue; Miou.Ownership.release res
    and pull prm = Option.map (fun a -> (a, prm)) (Bqueue.get bqueue)
    (* NOTE(dinosaure): A task that has completed successfully can be cancelled.
       The idea behind using [Miou.cancel] rather than [Miou.await_exn] is that
       the user may want to force the producer to terminate. Thanks to
       [Miou.Ownership], we can be sure that if [fn] raises an exception or is
       cancelled (with [Miou.cancel]), the queue is closed properly. *)
    and stop = Miou.cancel in
    Source { init; pull; stop }

  let with_formatter ?halt ~size fn =
    with_task ?halt ~size @@ fun q ->
    let out str off len = Bqueue.put q (String.sub str off len) in
    fn (Format.make_formatter out ignore)

  let each fn (Source src) =
    let rec go acc =
      match src.pull acc with
      | None -> src.stop acc
      | Some (x, acc) -> fn x; go acc
    in
    go (src.init ())

  let file ~filename len =
    if len <= 0 then invalid_arg "Flux.Source.file";
    let init () = (Bytes.create len, lazy (Stdlib.open_in_bin filename))
    and stop (_buf, ic) = if Lazy.is_val ic then close_in (Lazy.force ic)
    and pull ((buf, ic) as state) =
      let len = input (Lazy.force ic) buf 0 (Bytes.length buf) in
      if len = 0 then None else Some (Bytes.sub_string buf 0 len, state)
    in
    Source { init; stop; pull }

  let next (Source src) =
    let s0 = src.init () in
    try
      match src.pull s0 with
      | Some (x, s1) -> Some (x, Source { src with init= Fun.const s1 })
      | None -> None
    with exn -> src.stop s0; reraise exn
end

type ('a, 'r) sink =
  | Sink : {
        init: unit -> 's
      ; push: 's -> 'a -> 's
      ; full: 's -> bool
      ; stop: 's -> 'r
    }
      -> ('a, 'r) sink

module Sink = struct
  let fill x =
    let init = Fun.const ()
    and push _ = Fun.const ()
    and full = Fun.const true
    and stop = Fun.const x in
    Sink { init; push; full; stop }

  let string =
    let init () = Buffer.create 0x7ff in
    let push buf str = Buffer.add_string buf str; buf in
    let full = Fun.const false in
    let stop = Buffer.contents in
    Sink { init; push; full; stop }

  let list =
    let init () = [] in
    let push acc x =
      Log.debug (fun m -> m "Sink.list: new element");
      x :: acc
    in
    let full _ = false in
    let stop acc = List.rev acc in
    Sink { init; push; full; stop }

  let seq init =
    let init = Fun.const init in
    let push acc x = Seq.cons x acc in
    let full = Fun.const false in
    let stop = Fun.id in
    Sink { init; push; full; stop }

  let buffer len =
    if len < 0 then invalid_arg "Flux.Sink.buffer: negative buffer size";
    if len = 0 then fill [||]
    else
      let buf = Array.make len None in
      let init () = 0
      and push idx x = Array.set buf idx (Some x); idx + 1
      and full idx = idx = len
      and stop len = Array.init len (fun idx -> Option.get buf.(idx)) in
      Sink { init; push; full; stop }

  let file filename =
    let init () = lazy (Stdlib.open_out_bin filename) in
    let stop oc = if Lazy.is_val oc then close_out (Lazy.force oc) in
    let push oc str =
      let ch = Lazy.force oc in
      Stdlib.output_string ch str;
      Stdlib.flush ch;
      oc
    in
    let full _ = false in
    Sink { init; stop; full; push }

  let drain =
    let init () = () in
    let push () _ = () in
    let full () = false in
    let stop () = () in
    Sink { init; push; full; stop }

  let each ?(parallel = false) ~init ~merge fn =
    let rec terminate ?exn (acc, orphans) =
      match (Miou.care orphans, exn) with
      | None, None -> Ok (acc, orphans)
      | None, Some exn -> Error exn
      | Some None, _ ->
          Miou.yield ();
          terminate ?exn (acc, orphans)
      | Some (Some prm), _ -> (
          match (Miou.await prm, exn) with
          | Ok x, _ -> terminate ?exn (merge x acc, orphans)
          | Error exn, None ->
              Log.err (fun m ->
                  m "Sink.each: a task terminated abnormally: %s"
                    (Printexc.to_string exn));
              terminate ~exn (acc, orphans)
          | Error _, _ -> terminate ?exn (acc, orphans))
    in
    let rec clean (acc, orphans) =
      match Miou.care orphans with
      | None | Some None -> Ok (acc, orphans)
      | Some (Some prm) -> (
          match Miou.await prm with
          | Ok x -> clean (merge x acc, orphans)
          | Error exn ->
              Log.err (fun m ->
                  m "Sink.each: a task terminated abnormally: %s"
                    (Printexc.to_string exn));
              terminate ~exn (acc, orphans))
    in
    let init () = Ok (init, Miou.orphans ()) in
    let push value x =
      match Result.bind value clean with
      | Ok (acc, orphans) ->
          if parallel then ignore (Miou.call ~orphans @@ fun () -> fn x)
          else ignore (Miou.async ~orphans @@ fun () -> fn x);
          Ok (acc, orphans)
      | Error _ as err -> err
    in
    let full = Result.is_error in
    let stop x =
      match Result.(map fst (bind x terminate)) with
      | Ok acc -> acc
      | Error exn -> raise exn
    in
    Sink { init; stop; full; push }

  let sequential ~stop (Sink l) (Sink r) =
    let init () = (l.init (), r.init ())
    and push (l_acc, r_acc) x = (l.push l_acc x, r.push r_acc x)
    and full (l_acc, r_acc) = l.full l_acc || r.full r_acc
    and stop (l_acc, r_acc) = stop (l.stop l_acc, r.stop r_acc) in
    Sink { init; push; full; stop }

  let zip x y = sequential ~stop:Fun.id x y

  let parallel ~stop ~limit l r =
    let init () =
      let is_full = Atomic.make false in
      let lq = Bqueue.create Bqueue.with_close limit in
      let rq = Bqueue.create Bqueue.with_close limit in
      let fn (Sink s, q) =
        let rec go acc () =
          match Bqueue.get q with
          | Some x ->
              if s.full acc then (Atomic.set is_full true; s.stop acc)
              else go (s.push acc x) ()
          | None -> s.stop acc
        in
        go (s.init ())
      in
      let lprm = Miou.call (fn (l, lq)) in
      let rprm = Miou.call (fn (r, rq)) in
      (is_full, lq, lprm, rq, rprm)
    in
    let push ((_, lq, _, rq, _) as state) x =
      Bqueue.put lq x; Bqueue.put rq x; state
    in
    let full (is_full, _, _, _, _) = Atomic.get is_full in
    let stop (_, lq, lprm, rq, rprm) =
      Bqueue.close lq;
      Bqueue.close rq;
      let lres = Miou.await_exn lprm in
      let rres = Miou.await_exn rprm in
      stop (lres, rres)
    in
    Sink { init; push; full; stop }

  let both x y = parallel ~stop:Fun.id ~limit:0x7ff x y

  let unzip (Sink l) (Sink r) =
    let init () = (l.init (), r.init ())
    and push (l_acc, r_acc) (x, y) = (l.push l_acc x, r.push r_acc y)
    and full (l_acc, r_acc) = l.full l_acc || r.full r_acc
    and stop (l_acc, r_acc) = (l.stop l_acc, r.stop r_acc) in
    Sink { init; push; full; stop }

  type ('a, 'b) race = Left of 'a | Right of 'b | Both of 'a * 'b

  let race (Sink l) (Sink r) =
    let init () = Both (l.init (), r.init ())
    and push state x =
      match state with
      | Both (l_acc, r_acc) ->
          let l_acc' = l.push l_acc x in
          let r_acc' = r.push r_acc x in
          if l.full l_acc' then Left l_acc'
          else if r.full r_acc' then Right r_acc'
          else Both (l_acc', r_acc')
      | _ -> failwith "Flux.Sink.race: one of the sinks is already filled"
    in
    let full = function Both _ -> false | _ -> true in
    let stop = function
      | Left l_acc -> Left (l.stop l_acc)
      | Right r_acc -> Right (r.stop r_acc)
      | Both (l_acc, r_acc) -> Both (l.stop l_acc, r.stop r_acc)
    in
    Sink { init; push; full; stop }

  let map fn (Sink k) = Sink { k with stop= (fun x -> fn (k.stop x)) }

  type ('top, 'a, 'b) flat_map =
    | Flat_map_top : 'top -> ('top, 'a, 'b) flat_map
    | Flat_map_sub : {
          init: 'sub
        ; push: 'sub -> 'a -> 'sub
        ; full: 'sub -> bool
        ; stop: 'sub -> 'b
      }
        -> ('top, 'a, 'b) flat_map

  let flat_map fn (Sink top) =
    let init () = Flat_map_top (top.init ()) in
    let push s x =
      match s with
      | Flat_map_top acc ->
          let acc' = top.push acc x in
          if top.full acc' then
            let r = top.stop acc' in
            let (Sink sub) = fn r in
            Flat_map_sub
              {
                init= sub.init ()
              ; push= sub.push
              ; full= sub.full
              ; stop= sub.stop
              }
          else Flat_map_top acc'
      | Flat_map_sub sub -> Flat_map_sub { sub with init= sub.push sub.init x }
    in
    let full = function
      | Flat_map_top acc -> top.full acc
      | Flat_map_sub sub -> sub.full sub.init
    in
    let stop = function
      | Flat_map_top acc ->
          let (Sink sub) = fn (top.stop acc) in
          sub.stop (sub.init ())
      | Flat_map_sub sub -> sub.stop sub.init
    in
    Sink { init; push; full; stop }

  module Syntax = struct
    let ( let* ) x fn = flat_map fn x
    let ( let+ ) x fn = map fn x
    let ( and+ ) x y = zip x y
  end

  module Infix = struct
    let ( >>= ) x fn = flat_map fn x
    let ( <@> ) x fn = map fn x
    let ( <&> ) x y = zip x y
    let ( <|> ) x y = race x y

    let ( <*> ) l r =
      let stop (fn, x) = fn x in
      sequential ~stop l r
  end
end

type ('a, 'b) flow = { flow: 'r. ('b, 'r) sink -> ('a, 'r) sink } [@@unboxed]

module Flow = struct
  let identity = { flow= Fun.id }
  let compose { flow= f } { flow= g } = { flow= (fun sink -> f (g sink)) }
  let ( << ) a b = compose a b
  let ( >> ) b a = compose a b

  let tap fn =
    let flow (Sink k) =
      let push r x = fn x; k.push r x in
      Sink { k with push }
    in
    { flow }

  let map fn =
    let flow (Sink k) =
      let push r x = k.push r (fn x) in
      Sink { k with push }
    in
    { flow }

  let transfer bqueue push acc =
    let rec go acc () =
      match Bqueue.get bqueue with None -> acc | Some a -> go (push acc a) ()
    in
    go acc

  let filter fn =
    let flow (Sink k) =
      let push r x = if fn x then k.push r x else r in
      Sink { k with push }
    in
    { flow }

  let bound limit =
    let flow (Sink k) =
      let init () =
        let bqueue = Bqueue.(create with_close limit) in
        let acc = k.init () in
        let prm = Miou.async (transfer bqueue k.push acc) in
        (bqueue, prm)
      in
      let push (bqueue, prm) a = Bqueue.put bqueue a; (bqueue, prm) in
      let full _ = false in
      let stop (bqueue, prm) =
        Bqueue.close bqueue;
        let acc = Miou.await_exn prm in
        k.stop acc
      in
      Sink { init; stop; full; push }
    in
    { flow }
end

external reraise : exn -> 'a = "%reraise"

type 'a stream = { stream: 'r. ('a, 'r) sink -> 'r } [@@unboxed]

module Stream = struct
  let run ~from:(Source src) ~via:{ flow } ~into:snk =
    let (Sink snk) = flow snk in
    let rec loop r s =
      match snk.full r with
      | true ->
          let r' = snk.stop r in
          (* NOTE(dinosaure): it's really important to replace [init] by the
             current source's state. By this way, the user is able to
             [Source.dispose] without re-init the given source [src]. *)
          let leftover = Source { src with init= Fun.const s } in
          (r', Some leftover)
      | false -> begin
          match src.pull s with
          | Some (x, s') -> loop (snk.push r x) s'
          | None ->
              src.stop s;
              let r' = snk.stop r in
              (r', None)
        end
    in
    let r0 = snk.init () in
    match snk.full r0 with
    | true ->
        let r' = snk.stop r0 in
        (r', Some (Source src))
    | false -> (
        let s0' = ref None in
        try
          let s0 = src.init () in
          s0' := Some s0;
          loop r0 s0
        with exn ->
          Option.iter src.stop !s0';
          let _ = snk.stop r0 in
          reraise exn)

  let into sink t = t.stream sink

  let via { flow } t =
    let stream sink = into (flow sink) t in
    { stream }

  let from (Source src) =
    let stream (Sink k) =
      let rec go r s =
        let is_full = k.full r in
        if is_full then k.stop r
        else
          match src.pull s with
          | None -> src.stop s; k.stop r
          | Some (x, s') ->
              let r' = k.push r x in
              go r' s'
      in
      let r0 = k.init () in
      let is_full = k.full r0 in
      if is_full then k.stop r0
      else
        let s0' = ref None in
        try
          let s0 = src.init () in
          s0' := Some s0;
          go r0 s0
        with exn ->
          Log.err (fun m ->
              m "Stream.from: catch an exception: %s" (Printexc.to_string exn));
          Option.iter src.stop !s0';
          let _ = k.stop r0 in
          reraise exn
    in
    { stream }

  let map fn t = via (Flow.map fn) t
  let filter fn t = via (Flow.filter fn) t
  let file filename = into (Sink.file filename)
  let drain t = into Sink.drain t

  let each ?parallel fn t =
    into (Sink.each ?parallel ~init:() ~merge:Fun.const fn) t

  let interpose sep t =
    let stream (Sink k) =
      let started = ref false in
      let push acc x =
        match !started with
        | true ->
            let acc = k.push acc sep in
            if k.full acc then acc else k.push acc x
        | false ->
            started := true;
            k.push acc x
      in
      t.stream (Sink { k with push })
    in
    { stream }

  let _bracket : init:(unit -> 's) -> stop:('s -> 'r) -> ('s -> 's) -> 'r =
   fun ~init ~stop fn ->
    let acc = init () in
    try stop (fn acc)
    with exn ->
      ignore (stop acc);
      reraise exn

  let flat_map fn t =
    let stream (Sink k) =
      let push r x =
        (fn x).stream (Sink { k with init= Fun.const r; stop= Fun.id })
      in
      t.stream (Sink { k with push })
    in
    { stream }
end
