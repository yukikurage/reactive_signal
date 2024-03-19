import gleam/io
import gleam/erlang/process.{type Subject}
import gleam/otp/actor.{continue}

pub type Message {
  Request(reply_channel: Subject(String))
}

pub fn main() {
  let actor = actor.start(0, handle_message)

  // This returns Ok("Done")
  io.println("Hello from the parent process!")
}

fn handle_message(msg: Message, state) {
  io.println("The actor got a message")
  process.send(msg.reply_channel, "Done")
  actor.continue(state)
}
