# Flux, composable streaming abstractions with [Miou][miou]

Flux is a library that implements [a bounded queue][bqueue] as well as several
abstractions related to streams. It can take advantage of parallelisation as
proposed by Miou (with `Miou.call`), but also of the concept of ownership
(see `Miou.Ownership`) related to resources (such as file descriptors).

The advantage of flux is that it facilitates the composition of streams in order
to share information [_flux_][flux] between tasks.

[miou]: https://github.com/robur-coop/miou
[bqueue]: ./lib/bqueue.mli
[flux]: https://en.wiktionary.org/wiki/flux
