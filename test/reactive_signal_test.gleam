import gleeunit
import gleeunit/should
import gleam/io
import gleam/int
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import reactive_signal/channel

pub fn main() {
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
    fn(value, reply_with) {
      process.send(logger, "Listened:" <> int.to_string(value))

      // reply_with で subject を上位に渡すと、このリスナーが終了した時に subject で Nil を受信できる
      let subject = process.new_subject()
      process.send(reply_with, subject)

      process.new_selector()
      |> process.selecting(subject, fn(_) { Nil })
      |> process.select_forever

      process.send(logger, "Cleaned:" <> int.to_string(value))

      // Process の Exit を忘れない
      process.send_exit(process.self())
    }
  }

  let new_app = fn(logger: Subject(String)) {
    let chn = channel.new(0)
    channel.subscribe_with_cleaner(chn, new_listener(logger))
    process.sleep(10)
    channel.write(chn, 1)
    process.sleep(10)
    channel.write(chn, 2)
  }

  let logger = process.new_subject()
  let pid = process.start(fn() { new_app(logger) }, False)

  process.sleep(100)
  process.send_exit(pid)

  process.receive(logger, 10)
  |> should.equal(Ok("Listened:0"))

  process.receive(logger, 10)
  |> should.equal(Ok("Cleaned:0"))
  process.receive(logger, 10)
  |> should.equal(Ok("Listened:1"))

  process.receive(logger, 10)
  |> should.equal(Ok("Cleaned:1"))
  process.receive(logger, 10)
  |> should.equal(Ok("Listened:2"))
}
