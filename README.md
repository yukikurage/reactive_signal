# reactive_signal

A Gleam library for cross-process reactive signal

> [!WARNING]
> This is an experimental library, so breaking changes are actively made

[![Package Version](https://img.shields.io/hexpm/v/reactive_signal)](https://hex.pm/packages/reactive_signal)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/reactive_signal/)

```sh
gleam add reactive_signal
```

```gleam
import reactive_signal

pub fn main() {
  let new_listener = fn(logger) {
    fn(value) { process.send(logger, "Listened:" <> int.to_string(value)) }
  }

  let new_app = fn(logger: Subject(String)) {
    let #(sig, chn) = signal.new(0)
    let #(sig2, chn2) = signal.new(0)
    let sig3 = {
      use x <- signal.chain(sig)
      use y <- signal.chain(sig2)
      signal.pure(x + y)
    }
    signal.subscribe(sig3, new_listener(logger))
    channel.write(chn, 1)
    process.sleep(10)
    channel.write(chn2, 1)
    process.sleep(10)
  }

  let logger = process.new_subject()
  new_app(logger)

  process.receive(logger, 10)
  |> should.equal(Ok("Listened:0"))

  process.receive(logger, 10)
  |> should.equal(Ok("Listened:1"))

  process.receive(logger, 10)
  |> should.equal(Ok("Listened:2"))
}
```

Further documentation can be found at <https://hexdocs.pm/reactive_signal>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
gleam shell # Run an Erlang shell
```
