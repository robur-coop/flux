type infinite = |
type with_close = |
type with_close_and_halt = |

type ('a, 'k, 'r) s =
  | Uinfinite : ('a, infinite, 'a) s
  | Uwith_close : ('a, with_close, 'a option) s
  | Uwith_close_and_halt : ('a, with_close_and_halt, 'a option) s

type close = { closed: bool Atomic.t }
type close_and_halt = { closed: bool Atomic.t; halted: bool Atomic.t }

type ('a, 'r) k =
  | Infinite : ('a, 'a) k
  | With_close : close -> ('a, 'a option) k
  | With_close_and_halt : close_and_halt -> ('a, 'a option) k

(* NOTE(dinosaure): here, we need to re-implement a poor man condition.wait to
   ensure to be able to implement close/halt which don't emit effects. By this
   way, we can use Miou.Ownership and execute close/halt into a [finally]
   function. To do so, we use an atomic list (to be usable with several domains)
   which keeps registered waiters. A waiter is simply a [Miou.Trigger] and we
   are sure that when we [wakeup] registered [Miou.Trigger], they are executed
   effectfully (without interruption). *)

type waiters = Miou.Trigger.t list Atomic.t

type ('a, 'r) t = {
    buffer: 'a option array
  ; mutable rd_pos: int
  ; mutable wr_pos: int
  ; lock: Miou.Mutex.t
  ; non_empty: waiters
  ; non_full: waiters
  ; k: ('a, 'r) k
}

type 'a c = ('a, 'a option) t

let infinite = Uinfinite
let with_close = Uwith_close
let with_close_and_halt = Uwith_close_and_halt

let create : type a k r. (a, k, r) s -> int -> (a, r) t =
 fun s size ->
  let lock = Miou.Mutex.create () in
  let non_empty = Atomic.make [] in
  let non_full = Atomic.make [] in
  let buffer = Array.make size None in
  match s with
  | Uinfinite ->
      let k = Infinite in
      { buffer; lock; rd_pos= 0; wr_pos= 0; non_empty; non_full; k }
  | Uwith_close ->
      let k = With_close { closed= Atomic.make false } in
      { buffer; lock; rd_pos= 0; wr_pos= 0; non_empty; non_full; k }
  | Uwith_close_and_halt ->
      let closed = Atomic.make false in
      let halted = Atomic.make false in
      let k = With_close_and_halt { closed; halted } in
      { buffer; lock; rd_pos= 0; wr_pos= 0; non_empty; non_full; k }

let closed : type a r. (a, r) t -> bool =
 fun t ->
  match t.k with
  | Infinite -> false
  | With_close m -> Atomic.get m.closed
  | With_close_and_halt m -> Atomic.get m.halted || Atomic.get m.closed

let rec register waiters trigger =
  let seen = Atomic.get waiters in
  if not (Atomic.compare_and_set waiters seen (trigger :: seen)) then
    register waiters trigger

let wakeup waiters =
  match Atomic.get waiters with
  | [] -> ()
  | _ -> List.iter Miou.Trigger.signal (Atomic.exchange waiters [])

let wait t waiters =
  let trigger = Miou.Trigger.create () in
  register waiters trigger;
  if not (closed t) then begin
    Miou.Mutex.unlock t.lock;
    match Miou.Trigger.await trigger with
    | None -> Miou.Mutex.lock t.lock
    | Some (exn, bt) -> Printexc.raise_with_backtrace exn bt
  end

let unsafe_raise_if_closed : type a r. (a, r) t -> unit =
 fun t ->
  match t.k with
  | With_close { closed } | With_close_and_halt { closed; _ } ->
      if Atomic.get closed then invalid_arg "Flux.Bqueue.put: closed stream"
  | _ -> ()

let[@inline always] is_full t = (t.wr_pos + 1) mod Array.length t.buffer = t.rd_pos
let[@inline always] is_empty t = t.wr_pos = t.rd_pos

let put t data =
  Miou.Mutex.protect t.lock @@ fun () ->
  while is_full t && not (closed t) do
    wait t t.non_full
  done;
  unsafe_raise_if_closed t;
  t.buffer.(t.wr_pos) <- Some data;
  t.wr_pos <- (t.wr_pos + 1) mod Array.length t.buffer;
  wakeup t.non_empty

let get_from_infinite : type a. (a, a) t -> a =
 fun t ->
  Miou.Mutex.protect t.lock @@ fun () ->
  while is_empty t do
    wait t t.non_empty
  done;
  let data = t.buffer.(t.rd_pos) in
  t.buffer.(t.rd_pos) <- None;
  t.rd_pos <- (t.rd_pos + 1) mod Array.length t.buffer;
  wakeup t.non_full;
  Option.get data

let get_from_closeable : type a. (a, a option) t -> close -> a option =
 fun t m ->
  Miou.Mutex.protect t.lock @@ fun () ->
  while is_empty t && not (Atomic.get m.closed) do
    wait t t.non_empty
  done;
  if Atomic.get m.closed && is_empty t then None
  else
    let data = t.buffer.(t.rd_pos) in
    t.buffer.(t.rd_pos) <- None;
    t.rd_pos <- (t.rd_pos + 1) mod Array.length t.buffer;
    wakeup t.non_full;
    data

let[@inline always] not_closed_or_halted m =
  not (Atomic.get m.closed || Atomic.get m.halted)

let get_from_closeable_or_haltable : type a.
    (a, a option) t -> close_and_halt -> a option =
 fun t m ->
  Miou.Mutex.protect t.lock @@ fun () ->
  while is_empty t && not_closed_or_halted m do
    wait t t.non_empty
  done;
  match Atomic.get m.halted || (Atomic.get m.closed && is_empty t) with
  | true -> None
  | false ->
      let data = t.buffer.(t.rd_pos) in
      t.buffer.(t.rd_pos) <- None;
      t.rd_pos <- (t.rd_pos + 1) mod Array.length t.buffer;
      wakeup t.non_full;
      data

let get : type a r. (a, r) t -> r =
 fun t ->
  match t.k with
  | Infinite -> get_from_infinite t
  | With_close m -> get_from_closeable t m
  | With_close_and_halt m -> get_from_closeable_or_haltable t m

let close : type a r. (a, r) t -> unit =
 fun t ->
  match t.k with
  | Infinite -> ()
  | With_close m ->
      Atomic.set m.closed true;
      wakeup t.non_empty;
      wakeup t.non_full
  | With_close_and_halt m ->
      Atomic.set m.closed true;
      wakeup t.non_empty;
      wakeup t.non_full

let halt : type a r. (a, r) t -> unit =
 fun t ->
  match t.k with
  | Infinite -> ()
  | With_close m ->
      Atomic.set m.closed true;
      wakeup t.non_empty;
      wakeup t.non_full
  | With_close_and_halt m ->
      Atomic.set m.halted true;
      Atomic.set m.closed true;
      wakeup t.non_empty;
      wakeup t.non_full

let iter fn t =
  Miou.Mutex.protect t.lock @@ fun () ->
  if t.rd_pos < t.wr_pos then
    for idx = t.rd_pos to t.wr_pos - 1 do
      fn (Option.get t.buffer.(idx))
    done
  else if t.rd_pos > t.wr_pos then begin
    for idx = t.rd_pos to Array.length t.buffer - 1 do
      fn (Option.get t.buffer.(idx))
    done;
    for idx = 0 to t.wr_pos - 1 do
      fn (Option.get t.buffer.(idx))
    done
  end

let of_list vs =
  let size = List.length vs + 1 in
  let stream = create with_close size in
  List.iter (put stream) vs;
  close stream;
  stream

let to_seq : type a r. (a, r) t -> a Seq.t =
 fun t ->
  match t.k with
  | Infinite -> Seq.forever (fun () -> get t)
  | With_close _ -> Seq.of_dispenser (fun () -> get t)
  | With_close_and_halt _ -> Seq.of_dispenser (fun () -> get t)

let single v =
  let stream = create with_close 2 in
  put stream v; close stream; stream
