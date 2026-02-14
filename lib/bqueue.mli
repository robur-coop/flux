(** {1 A bounded-queue.}

    [Bqueue] is a domain-safe implementation of a limited queue (in terms of
    memory). This means that as soon as the size limit is reached, when you want
    to fill the queue, the task responsible for filling is suspended and will
    only continue when another task has consumed at least one element from the
    queue. This way, you can be sure of the memory consumption of a process.

    There are three types of queues:
    - {!type:infinite} queues
    - queues that can be closed ({!type:with_close})
    - queues that can be closed or signal the end of consumption (as we say be
      halted) ({!type:with_close_and_halt})

    {2 Infinite queue.}

    An infinite queue is useful when you know that the consumer is a task that
    should never be interrupted throughout the program.

    It is very useful when you want to launch a background task that can perform
    certain actions throughout the lifetime of your program. Only cancellation
    ([Miou.cancel]) is then possible to stop this task (which should run
    forever).

    {[
      let daemon () =
        let q = Flux.Bqueue.(create infinite 0x7ff) in
        let rec go () =
          let `Are_you_alive = Flux.Bqueue.get q in
          print_endline "I'm alive!";
          go ()
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
    ]}

    Thanks to the type system, [Flux.Bqueue.get] only returns values and will
    never return [None] since it is an infinite queue.

    {2 Closeable queue.}

    Miou only allows values to be transmitted between children and its parent.
    Any other mechanism for transmitting information requires a more complex
    structure (such as an atomic, a queue, etc.) depending on whether the tasks
    operate cooperatively or in parallel.

    Thus, a fairly common structure is a queue, where one task is responsible
    for filling it and another task is responsible for consuming it. [Bqueue] is
    this queue with the advantage of being {b domain-safe} (unlike
    [Stdlib.Queue]): that is, it can be used with [Miou.async] (for cooperative
    tasks) or [Miou.call] (for parallel tasks).

    Since all tasks should be completed, it is necessary to have a signal to
    tell the consumer that the producer has no more information to transmit.
    This is referred to as a {i closeable} queue.

    {[
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
        let q = FLux.Bqueue.(create with_close 0x7ff) in
        let ic = open_in Sys.argv.(1) in
        let@ () = fun () -> close_in ic in
        let max = in_channel_length ic in
        let prm0 = consumer q max and prm1 = producer q ic in
        Miou.await_all [ prm0; prm1 ]
        |> List.iter (function Ok () -> () | Error exn -> raise exn)
    ]}

    It is ensured that the consumer (unless cancelled) consumes all the elements
    sent by the producer. Note the use of [Miou.async] and [Miou.call] in the
    example above.

    There are many examples of this type of queue, and you can refer to our
    tutorial on how to use this module with the streams we offer in this
    library.

    {2 Closeable and haltable queue.}

    There is one last type of queue called a {i haltable} queue. Sometimes you
    may want to have an infinite queue but still be able to close it so that the
    consumer does not consume from it indefinitely.

    Unlike closing, halting a queue informs the consumer that there should be no
    more items, even if the producer has produced some. These items are then
    ignored, and the consumer, even if it has not consumed everything, receives
    the signal that the queue should no longer produce anything.

    {[
      let random q =
        let ic = open_in "/dev/urandom" in
        let icr = Miou.Ownership.create ~finally:close_in ic in
        let qr = Miou.Ownership.create ~finally:Flux.Bqueue.halt q in
        Miou.Ownership.own icr;
        Miou.Ownership.own qr;
        let buf = Bytes.create 0x7ff in
        let rec go () =
          match input ic buf 0 (Bytes.length buf) with
          | 0 | (exception End_of_file) ->
              Miou.Ownership.release icr;
              Miou.Ownership.release qr
          | len ->
              let str = Bytes.sub_string buf 0 len in
              Flux.Bqueue.put q str; got ()
        in
        Miou.call ~give:[ icr; qr ] go

      let entropy q =
        let freqs = Array.make 256 0 in
        let rec go iter () =
          match Flux.Bqueue.get q with
          | None ->
              let total = Array.fold_left Int.add 0 freqs in
              let total = FLoat.of_int total in
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
              let fn chr = freqs.(Char.code chr) <- freqs.(Char.code chr) + 1 in
              String.iter fn str;
              go (succ iter) ()
        in
        Miou.async (go 0)

      let () =
        Miou_unix.run ~domains:1 @@ fun () ->
        let q = Flux.Bqueue.(create with_close_and_halt 0x7ff) in
        let prm0 = random q and prm1 = entropy q in
        Miou_unix.sleep 1.;
        Miou.cancel prm0;
        let entropy, iter = Miou.await_exn prm1 in
        Format.printf "Entropy %f (%d iteration(s))\n%!" entropy iter
    ]}

    In the example above, there is an infinite source of random values. We also
    want a task to calculate the entropy of what [/dev/urandom] generates.
    However, we would like the consumer to finalise its result as soon as our
    random value generator halts (with [Flux.Bqueue.halt]).

    Cancelling our task [random] calls the [finally] associated with our
    resource [qr], which then executes [Flux.Bqueue.halt].

    {2 Ownership and [Bqueue].}

    Closing and/or halting a [Bqueue] queue has no effect, so it is safe to
    create a resource (in Miou's terms) and use [Flux.Bqueue.close] and/or
    [Flux.Bqueue.halt] as {i finally}.

    {2 Bounded queue.}

    The principle of a queue with a limited size has one disadvantage: there
    {b must be} a consumer that runs cooperatively (or in parallel) with the
    producer. If this is not the case (and the producer and consumer are running
    sequentially, for example), a {i deadlock} can occur: since no one is
    consuming and the queue is full, the producer will be in an infinite wait.

    This therefore requires discipline on the part of the user to properly
    initiate a producer and a consumer cooperatively and/or in parallel.

    However, the advantage of such a queue is the predictability of memory
    usage. This is particularly true when the source is not controlled: for
    example, when a user wants to upload a file.

    From experience, and particularly when developing applications as services,
    it is preferable to use a bounded queue. This is because using a simple
    queue makes its memory usage closely linked to how the scheduler orders
    tasks: will it only execute the producer until it finishes? Will it give the
    consumer the opportunity to execute? Will the consumer attempt to execute
    before or after the producer? Can we ensure that the execution of the
    producer and consumer are interleaved?

    Given all these questions, we recommend using a bounded queue rather than a
    {i stream} for which adding is never blocking. *)

type ('a, 'r) t
(** Type of bounded queues. *)

type 'a c = ('a, 'a option) t
(** Type of closeable (and possibly haltable) bounded queue. *)

(** {3 Types of bounded-queue.} *)

type infinite
type with_close
type with_close_and_halt

type ('a, 'k, 'r) s
(** Type to describe bounded-queue's behaviors. *)

val infinite : ('a, infinite, 'a) s
(** [infinite] permits to {!val:create} an {i infinite} bounded-queue. *)

val with_close : ('a, with_close, 'a option) s
(** [with_close] permits to {!val:create} a {i closeable} bounded-queue. *)

val with_close_and_halt : ('a, with_close_and_halt, 'a option) s
(** [with_close_and_halt] permits to {!val:create} a {i closeable} and
    {i haltable} bounded-queue. *)

val create : ('a, 'k, 'r) s -> int -> ('a, 'r) t
(** [create s size] creates a new bounded-queue. *)

val put : ('a, 'r) t -> 'a -> unit
(** [put q x] adds the element [x] at the end of the queue [q]. *)

val get : ('a, 'r) t -> 'r
(** [get q] removes and returns the first element in queue [q]. Depending on the
    type of the given bounded-queue, [get] always returns an element if it's an
    {!type:infinite} bounded-queue or [get] returns [None] if the queue is
    closed and/or halted. *)

val close : ('a, 'r) t -> unit
(** [close q] closes the given bounded-queue [q]. All subsequent {!val:put}
    calls will raise an exception. If the producer has any pending elements,
    consumer will have an opportunity to {!val:get} them before receiving
    [None]. [close q] does nothing for an infinite queue. *)

val halt : ('a, 'r) t -> unit
(** [halt q] halts the given bounded-queue [q]. All subsequent {!val:put} calls
    will raise an exception. If the producer has any pending elements, they will
    be {b discarded} if the given [q] is a {!type:with_close_and_halt}
    bounded-queue. [halt q] has the same effect than {!val:close} for a
    {!type:with_close} bounded-queue. [halt q] does nothing for an infinite
    queue. *)

val iter : ('a -> unit) -> ('a, 'r) t -> unit
(** [iter fn q] applies fn in turn to all elements of [q], from the least
    recently entered to the most recently entered. The queue itself is
    unchanged. *)

val of_list : 'a list -> ('a, 'a option) t
val single : 'a -> ('a, 'a option) t
val closed : ('a, 'r) t -> bool
val to_seq : ('a, 'r) t -> 'a Seq.t
