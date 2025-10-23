(** Flux is a library that provides an interface for manipulating streams with
    the Miou scheduler. We strongly recommend that you familiarise yourself with
    Miou and read our tutorial. *)

module Bqueue = Bqueue

(** {1:sources Sources.}

    Sources are decoupled producer of values.

    Elements are pulled from a source when needed. A source can have an internal
    state that will be lazily initialized when (and if) a consumer requests
    elements. The internal state will be safety disposed when the source runs
    out of elements, when the consumer terminates, or if an exception is raised
    at any point in the streaming pipeline.

    Sources are a great way to define decoupled producers that can be consumed
    with {!val:Stream.from}. Sources are {i single shot} and will have their
    input exhausted by most operations. Consider {{!val:Sink.buffer} buffering}
    sources if you need to reuse their input.

    The following example creates a source that counts down to zero:

    {[
      # let countdown n =
          let init () = n
          and pull = function
            | 0 -> None
            | n -> Some (n, n - 1)
          and stop = Fun.id in
          Flux.Source.Source { init; pull; stop }
      ;;
      # Stream.(from (countdown 3) |> into Sink.sum) ;;
      - : int = 6
    ]} *)

type +'a source =
  | Source : {
        init: unit -> 's
      ; pull: 's -> ('a * 's) option
      ; stop: 's -> unit
    }
      -> 'a source  (** Type of sources that produce elements of type ['a]. *)

module Source : sig
  val unfold : 's -> ('s -> ('a * 's) option) -> 'a source
  (** [unfold seed next] is a finite source created from a [seed] state and a
      function that produces elements and an updated state. *)

  val empty : 'a source
  (** An empty source. *)

  val list : 'a list -> 'a source
  (** [list items] is a source with all elements from the [items] list. *)

  val seq : 'a Seq.t -> 'a source
  (** [seq items] is a source with all elements from the [items] sequence. *)

  val array : 'a array -> 'a source
  (** [array items] is a source with all elements from the [items] array. *)

  val string : string -> char source
  (** [string str] is a source with all characters from the [str] string. *)

  val queue : 'a Queue.t -> 'a source
  (** [queue q] is a source with all elements from the [q] queue. *)

  val resource : finally:('r -> unit) -> ('r -> 'a option) -> 'r -> 'a source
  (** [resource ~finally pull value] creates a new resource from a [pull]
      function and an initial value. [resource] uses Miou's ownership mechanism
      so that if the task consuming the resource is cancelled, the resource is
      properly released (and [finally] is executed).

      This also {b requires} the user to {!val:dispose} the source at the end of
      the task, otherwise Miou's rules will be violated.

      {b NOTE}: The resource passed to the [pull] function is {b physically} the
      same as [init]. *)

  type 'a task = ('a, 'a option) Bqueue.t -> unit
  (** Type of tasks which should fill a given bounded-queue. *)

  val with_task : ?halt:bool -> size:int -> 'a task -> 'a source
  (** [with_task ?halt size producer] returns a source that is linked to a task
      [producer] producing elements of type ['a]. The transfer of elements
      between the task and the source consumer is limited in memory by [size]
      elements at a time.

      The source is not effective and may potentially block if the shared queue
      is empty and an attempt is made to consume it (via {!val:next}, for
      example). The shared queue is automatically closed/halted (depending on
      [?halt], defaults to [false]) as soon as the producer terminates.

      For more details on the difference between [halt] and [close], please
      refer to the {!module:Bqueue} module. *)

  val with_formatter :
    ?halt:bool -> size:int -> (Format.formatter -> unit) -> string source

  val bqueue :
    ?stop:[ `Ignore | `Halt | `Close ] -> ('a, 'a option) Bqueue.t -> 'a source
  (** [bqueue ?stop q] is a source with all iterms from the [q] bounded-queue.

      The user can choose how to {!val:dispose} the given bounded-queue [q]:
      - [`Ignore] does nothing
      - [`Halt] {!val:Bqueue.halt} the given bounded-queue [q]
      - [`Close] {!val:Bqueue.close} the given bounded-queue [q]

      {b NOTE}: [`Halt] a bounded-queue created with {!val:Bqueue.with_close}
      also closes the given bounded-queue. *)

  val map : ('a -> 'b) -> 'a source -> 'b source

  val each : ('a -> unit) -> 'a source -> unit
  (** [each fn src] applies an effectful function [fn] to all elements in [src].
  *)

  val file : filename:string -> int -> string source
  (** [file ~filename len] *)

  val next : 'a source -> ('a * 'a source) option
  (** [next src] is [Some (x, rest)] where [x] is the first element of [src] and
      [rest] is [src] without [x]; or [None], if [src] is empty.

      {b NOTE}: If [rest] is produced, it is required to either consume it or
      manually {{!val:dispose} dispose} its resources. Not doing so might lead
      to resource leaks. *)

  (** {2 Resource handling.} *)

  val dispose : 'a source -> unit
  (** [dispose src] {b forces} the termination of the source data. This function
      is useful in situations when a leftover source is produced in
      {!val:Stream.run}.

      {b NOTE}: If the source is not already initialized, calling this function
      will first initialize its state before it is terminated. *)
end

(** {1:sinks Sinks.}

    Sinks are decoupled consumer of values.

    Sinks are streaming abstractions that consume values and produce an
    aggregated value as a result. The result value is extracted from an internal
    state that is built incrementally. The internal state can acquire resources
    that are guaranteed to be terminated when the sink is filled.

    Sinks are a great way to define decoupled consumers that can be filled with
    {!val:Stream.into}.

    The following example demonstrates a sink that consumes all elements into a
    list:

    {[
      let list =
        let init () = []
        and push acc x = x :: acc
        and stop acc = List.rev acc
        and full _ = false in
        Flux.Stream.Sink { init; push; full; stop }
    ]}

    Sinks are independent from sources and streams. You can think of them as
    packed arguments for folding functions with early termination. *)

type ('a, 'r) sink =
  | Sink : {
        init: unit -> 's
      ; push: 's -> 'a -> 's
      ; full: 's -> bool
      ; stop: 's -> 'r
    }
      -> ('a, 'r) sink
      (** Types for sinks that consume elements of type ['a] and, once done,
          produce a value of type ['b]. *)

module Sink : sig
  val string : (string, string) sink
  (** Consumes and concatenates bytes. *)

  val list : ('a, 'a list) sink
  (** Puts all input elements into a list. *)

  val seq : 'a Seq.t -> ('a, 'a Seq.t) sink
  (** [seq s] puts all input elements into the given [s]. *)

  val buffer : int -> ('a, 'a array) sink
  (** Similar to {!val:array} but will only consume [n] elements. *)

  val fill : 'r -> ('a, 'r) sink
  (** [fill x] uses [x] to fill the sink. This sink will not consume any input
      and will immediately produce [x] when used. *)

  val zip : ('a, 'r0) sink -> ('a, 'r1) sink -> ('a, 'r0 * 'r1) sink
  (** [zip l r] computes both [l] and [r] cooperatively with the same input
      being sent to both sinks. The results of both sinks are produced. *)

  val both : ('a, 'r0) sink -> ('a, 'r1) sink -> ('a, 'r0 * 'r1) sink
  (** [both l r] computes both [l] and [r] {b in parallel} with the same input
      being sent to both sinks. The results of both sinks are produced. *)

  val unzip : ('a, 'r0) sink -> ('b, 'r1) sink -> ('a * 'b, 'r0 * 'r1) sink
  (** [unzip l r] is a sink that receives pairs ['a * 'b], sending the first
      element into [l] and the second into [r]. Both sinks are computed
      cooperatively and their results returned as an output pair.

      The sink becomes full when either [l] or [r] get full. *)

  type ('a, 'b) race = Left of 'a | Right of 'b | Both of 'a * 'b

  val race : ('a, 'r0) sink -> ('a, 'r1) sink -> ('a, ('r0, 'r1) race) sink
  (* [race l r] runs both [l] and [r] sinks cooperatively producing the result
     for the one that fills first.

     If the sink is terminated prematurely, before either [l] or [r] are filled,
     {!constructor:Both} of their values are produced. *)

  val each :
       ?parallel:bool
    -> init:'a
    -> merge:('b -> 'a -> 'a)
    -> ('c -> 'b)
    -> ('c, 'a) sink
  (** [each ?parallel ~init ~merge fn] applies [fn] to all input elements and
      [merge] producing results with [init]. If [parallel] is [true] (default is
      [false]), [fn] is executed in parallel to the domain in which the {i sink}
      is executed. Otherwise, the actions are executed cooperatively. If one of
      these actions terminates abnormally, the execution of the returned
      {i sink} raises an exception. *)

  val file : string -> (string, unit) sink

  module Syntax : sig
    val ( let* ) : ('a, 'r0) sink -> ('r0 -> ('a, 'r1) sink) -> ('a, 'r1) sink
    val ( let+ ) : ('a, 'r0) sink -> ('r0 -> 'r1) -> ('a, 'r1) sink
    val ( and+ ) : ('a, 'r0) sink -> ('a, 'r1) sink -> ('a, 'r0 * 'r1) sink
  end

  module Infix : sig
    val ( >>= ) : ('a, 'r0) sink -> ('r0 -> ('a, 'r1) sink) -> ('a, 'r1) sink
    val ( <*> ) : ('a, 'r0 -> 'r1) sink -> ('a, 'r0) sink -> ('a, 'r1) sink
    val ( <@> ) : ('a, 'r0) sink -> ('r0 -> 'r1) -> ('a, 'r1) sink
    val ( <&> ) : ('a, 'r0) sink -> ('a, 'r1) sink -> ('a, 'r0 * 'r1) sink
    val ( <|> ) : ('a, 'r0) sink -> ('a, 'r1) sink -> ('a, ('r0, 'r1) race) sink
  end
end

(** {1:flows Flows.}

    Flows are decoupled transformers of values.

    Flows define streaming transformation, filtering or grouping operations that
    are fully disconnected from input and output. Their implementation
    intercepts an internal folding function and modifies the input one value at
    a time.

    Flows are great way to define decoupled transformations that can be used
    with {!val:Stream.via}.

    A flow can be applied to a stream with {!val:Stream.via}:

    {[
      # Stream.range 10 100
        |> Stream.via (Flow.map (fun x -> x + 1))
        |> Stream.into Sink.sum
      - : int = 4995
    ]}

    Flows can also be composed to form a pipeline:

    {[
      # let a = Flow.map (fun x -> x + 1) in
        let b = Flow.filter (fun x -> x mod 2 = 0) in
        Stream.range 10 100
        |> Stream.via Flow.(a >> b)
        |> Stream.into Sink.sum
      - : int = 2475
    ]} *)

type ('a, 'b) flow = { flow: 'r. ('b, 'r) sink -> ('a, 'r) sink } [@@unboxed]
(** Stream transformers that consume values of type ['a] and produce values of
    type ['b]. *)

module Flow : sig
  val identity : ('a, 'a) flow
  (** A neutral flow that does not change the elements. *)

  val tap : ('a -> unit) -> ('a, 'a) flow
  (** A flow with all elements passed through an effectful function. *)

  val filter : ('a -> bool) -> ('a, 'a) flow
  (** A flow that includes only elements that satisfy a predicate. *)

  val compose : ('a, 'b) flow -> ('b, 'c) flow -> ('a, 'c) flow
  (** Compose two flows to form a new flow. *)

  val ( >> ) : ('a, 'b) flow -> ('c, 'a) flow -> ('c, 'b) flow
  (** [f1 << f2] is [compose f1 f2]. *)

  val ( << ) : ('a, 'b) flow -> ('b, 'c) flow -> ('a, 'c) flow
  (** [f1 >> f2] is [compose f2 f1]. *)

  val bound : int -> ('a, 'a) flow
  (** [bounds] limits the consumption of an infinite source to a source with
      bounded memory consumption. Indeed, the effective aspect of consuming a
      source, transforming it, and producing a final value (in other words,
      {!val:Stream.run}) can lead (depending on the source) to a peak in memory
      usage that will only end when the process terminates, leaving no room for
      other processes to run (in parallel and/or cooperatively) correctly (and
      surely ending in an [Out_of_memory] exception if we are in a restricted
      context). *)
end

(** {1:streams Streams.}

    Streams combine sources, sinks and flows into a flexible streaming toolkit.

    Stream is a purely functional abstraction for incremental, push-based,
    sequential processing of elements. Streams can be easily and efficiently
    transformed and concatenated.

    Stream operations do not leak resources. This is guaranteed in the presence
    of early termination (when not all stream elements are consumed) or in case
    of exceptions in the streaming pipeline.

    Streams are built to be compatible with {{:#sources} sources},
    {{:#sinks} sinks} and {{:#flows} flows}. To create a stream that produces
    all elements from a source use {!val:Stream.from}. to consume a stream with
    a sink use {!val:Stream.into} and to transform stream elements with a flow
    use {!val:Stream.via}. For more sophisticated pipelines that might have
    source leftovers, {!val:Stream.run} can be used. *)

type 'a stream = { stream: 'r. ('a, 'r) sink -> 'r } [@@unboxed]
(** Type for streams with elements of type ['a]. *)

module Stream : sig
  val run :
       from:'a source
    -> via:('a, 'b) flow
    -> into:('b, 'c) sink
    -> 'c * 'a source option
  (** Fuses sources, sinks and flows and produces a result and a leftover.

      {[
        let r, leftover = Stream.run ~from:source ~via:flow ~into:sink
      ]}

      Streams elements from [source] into [sink] via a stream transformer
      [flow]. In addition to the result value [r] produced by [sink], a
      [leftover] source is returned, if [source] was not exhausted.

      {b NOTE}: If a leftover source is produced, it is required to either
      consume it or manually {{!val:Source.dispose} dispose} its resources. Not
      doing so might lead to resource leaks. *)

  val into : ('a, 'b) sink -> 'a stream -> 'b
  (** [into sink stream] is the result value produced by streaming all elements
      of [stream] into [sink]. *)

  val via : ('a, 'b) flow -> 'a stream -> 'b stream
  (** [via flow stream] is stream produced by transforming all elements of
      [stream] via [flow]. *)

  val from : 'a source -> 'a stream
  (** [from source] is a stream created from a source. *)

  val map : ('a -> 'b) -> 'a stream -> 'b stream
  (** A stream with all elements transformed with a mapping function. *)

  val flat_map : ('a -> 'b stream) -> 'a stream -> 'b stream
  (** [flat_map fn stream] is a stream concatenated from sub-streams produced by
      applying [fn] to all elements of [stream]. *)

  val filter : ('a -> bool) -> 'a stream -> 'a stream
  (** A stream that includes only the elements that satisfy a predicate. *)

  val file : string -> string stream -> unit
  (** [file filename stream] writes bytes from [stream] into the file located at
      [filename]. *)

  val drain : 'a stream -> unit

  val interpose : 'a -> 'a stream -> 'a stream
  (** Inserts a separator element between each stream element. *)

  val each : ?parallel:bool -> ('a -> unit) -> 'a stream -> unit
  (** [each fn stream] applies an function [fn] to all elements of stream. Each
      function is performed cooperatively via the Miou scheduler. *)
end
