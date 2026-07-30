## v0.0.1~beta7 (2026-07-30)

- Fix `Flux_tar` (@dinosaure, @hannesm, #26)

## v0.0.1~beta6 (2026-07-28)

- Update `fluxt.tar` with `tar.3.5.0` (#19, @dinosaure)
- Be able to decide the size of the buffer for `Flux_angstrom` (#20, @dinosaure)
- Add `Flux_unzip` (`fluxt.unzip`) (#22, @dinosaure)
- Fix a `assert false` on `Flux_de` (#22, spotted by @voodoos, fixed by @dinosaure)
- Use `Mirage_crypto_rng_unix.use_default` (#23, @dinosaure, @hannesm)
- Add `Flux.Flow.tee` (#24, @theAlexes, @dinosaure)

## v0.0.1~beta5 (2026-04-21)

- Fix `Flux.Source.with_buffered_formatter` (@reynir, #16)

## v0.0.1~beta4 (2026-04-09)

- Add `Flux.Stream.concat` (@dinosaure, #12)
- Add `Flux.Source.with_buffered_formatter` (@reynir, #13)
- Dispose properly a source when we use `Flux.Stream.from` (@dinosaure, spotted by @Josef-Thorne-A, #14)

## v0.0.1~beta3 (2026-02-17)

- Add `Flux.Sink.bqueue` (@dinosaure, #10)

## v0.0.1~beta2 (2026-01-20)

- Add a test about `miou` and fix `Source.with_task` (@dinosaure, #3, #4, #5, #6)
- Add `Flux_zip` (@dinosaure, #7)
- Add `Flux_angstrom` (@dinosaure, #8)

## v0.0.1~beta1 (2025-10-30)

- First release of Flux and Fluxt
