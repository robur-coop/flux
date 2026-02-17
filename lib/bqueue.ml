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

type ('a, 'r) t = {
    buffer: 'a option array
  ; mutable rd_pos: int
  ; mutable wr_pos: int
  ; lock: Miou.Mutex.t
  ; non_empty: Miou.Condition.t
  ; non_full: Miou.Condition.t
  ; k: ('a, 'r) k
}

type 'a c = ('a, 'a option) t

let infinite = Uinfinite
let with_close = Uwith_close
let with_close_and_halt = Uwith_close_and_halt

let create : type a k r. (a, k, r) s -> int -> (a, r) t =
 fun s size ->
  let lock = Miou.Mutex.create () in
  let non_empty = Miou.Condition.create () in
  let non_full = Miou.Condition.create () in
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

let unsafe_raise_if_closed : type a r. (a, r) t -> unit =
 fun t ->
  match t.k with
  | With_close { closed } | With_close_and_halt { closed; _ } ->
      if Atomic.get closed then invalid_arg "Flux.Bqueue.put: closed stream"
  | _ -> ()

let put t data =
  Miou.Mutex.protect t.lock @@ fun () ->
  unsafe_raise_if_closed t;
  while (t.wr_pos + 1) mod Array.length t.buffer = t.rd_pos do
    Miou.Condition.wait t.non_full t.lock
  done;
  t.buffer.(t.wr_pos) <- Some data;
  t.wr_pos <- (t.wr_pos + 1) mod Array.length t.buffer;
  Miou.Condition.signal t.non_empty

let get_from_infinite : type a. (a, a) t -> a =
 fun t ->
  Miou.Mutex.protect t.lock @@ fun () ->
  while t.wr_pos = t.rd_pos do
    Miou.Condition.wait t.non_empty t.lock
  done;
  let data = t.buffer.(t.rd_pos) in
  t.buffer.(t.rd_pos) <- None;
  t.rd_pos <- (t.rd_pos + 1) mod Array.length t.buffer;
  Miou.Condition.signal t.non_full;
  Option.get data

let get_from_closeable : type a. (a, a option) t -> close -> a option =
 fun t m ->
  Miou.Mutex.protect t.lock @@ fun () ->
  while t.wr_pos = t.rd_pos && not (Atomic.get m.closed) do
    Miou.Condition.wait t.non_empty t.lock
  done;
  if Atomic.get m.closed && t.wr_pos = t.rd_pos then None
  else
    let data = t.buffer.(t.rd_pos) in
    t.buffer.(t.rd_pos) <- None;
    t.rd_pos <- (t.rd_pos + 1) mod Array.length t.buffer;
    Miou.Condition.signal t.non_full;
    data

let[@inline always] not_closed_or_halted m =
  not (Atomic.get m.closed || Atomic.get m.halted)

let closed : type a r. (a, r) t -> bool =
 fun t ->
  match t.k with
  | Infinite -> false
  | With_close m -> Atomic.get m.closed
  | With_close_and_halt m -> Atomic.get m.halted || Atomic.get m.closed

let get_from_closeable_or_haltable : type a.
    (a, a option) t -> close_and_halt -> a option =
 fun t m ->
  Miou.Mutex.protect t.lock @@ fun () ->
  while t.wr_pos = t.rd_pos && not_closed_or_halted m do
    Miou.Condition.wait t.non_empty t.lock
  done;
  match Atomic.get m.halted || (Atomic.get m.closed && t.wr_pos = t.rd_pos) with
  | true -> None
  | false ->
      let data = t.buffer.(t.rd_pos) in
      t.buffer.(t.rd_pos) <- None;
      t.rd_pos <- (t.rd_pos + 1) mod Array.length t.buffer;
      Miou.Condition.signal t.non_full;
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
      Miou.Condition.signal t.non_empty
  | With_close_and_halt m ->
      Atomic.set m.closed true;
      Miou.Condition.signal t.non_empty

let halt : type a r. (a, r) t -> unit =
 fun t ->
  match t.k with
  | Infinite -> ()
  | With_close m ->
      Atomic.set m.closed true;
      Miou.Condition.signal t.non_empty
  | With_close_and_halt m ->
      Atomic.set m.closed true;
      Atomic.set m.halted true;
      Miou.Condition.signal t.non_empty

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
