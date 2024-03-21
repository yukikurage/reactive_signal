import gleeunit
import gleeunit/should
import gleam/int
import gleam/erlang/process.{type Subject}
import reactive_signal/channel
import reactive_signal/signal
import gleam/set

pub fn main() {
  // channel_test()
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  1
  |> should.equal(1)
}

pub fn channel_test() {
  // リスナー Actor
  let new_listener = fn(logger) {
    fn(value, wait_next) {
      process.send(logger, "Listened:" <> int.to_string(value))
      wait_next()
      process.send(logger, "Cleaned:" <> int.to_string(value))
    }
  }

  let new_app = fn(logger: Subject(String)) {
    let chn = channel.new(0)
    channel.subscribe_with_wait_next(chn, new_listener(logger))
    process.sleep(10)
    channel.write(chn, 1)
    process.sleep(10)
    channel.write(chn, 2)
    process.sleep(10)
  }

  let logger = process.new_subject()
  process.start(fn() { new_app(logger) }, False)

  process.sleep(100)

  process.receive(logger, 10)
  |> should.equal(Ok("Listened:0"))

  [process.receive(logger, 10), process.receive(logger, 10)]
  |> set.from_list
  |> should.equal(set.from_list([Ok("Cleaned:0"), Ok("Listened:1")]))

  [process.receive(logger, 10), process.receive(logger, 10)]
  |> set.from_list
  |> should.equal(set.from_list([Ok("Cleaned:1"), Ok("Listened:2")]))

  process.receive(logger, 10)
  |> should.equal(Ok("Cleaned:2"))
}

pub fn nested_channel_test() {
  // リスナー Actor
  let new_listener = fn(logger, parent_value) {
    fn(value) {
      process.send(
        logger,
        "Listened:"
          <> int.to_string(parent_value)
          <> ","
          <> int.to_string(value),
      )
    }
  }

  let new_sub_app = fn(logger) {
    fn(value) {
      let chn = channel.new(0)
      channel.subscribe(chn, new_listener(logger, value))
      process.sleep(10)
      channel.write(chn, 1)
      process.sleep(10)
    }
  }

  let new_app = fn(logger: Subject(String)) {
    let chn = channel.new(0)
    channel.subscribe(chn, new_sub_app(logger))
    process.sleep(100)
    channel.write(chn, 1)
    process.sleep(10)
  }

  let logger = process.new_subject()
  process.start(fn() { new_app(logger) }, False)

  process.sleep(200)

  process.receive(logger, 10)
  |> should.equal(Ok("Listened:0,0"))

  process.receive(logger, 10)
  |> should.equal(Ok("Listened:0,1"))

  process.receive(logger, 10)
  |> should.equal(Ok("Listened:1,0"))

  process.receive(logger, 10)
  |> should.equal(Ok("Listened:1,1"))
}

pub fn signal_test() {
  // リスナー Actor
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
