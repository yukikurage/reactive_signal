import gleam/io
import gleam/erlang/process.{type Subject}

pub fn main() {
  let process = fn() { process.sleep_forever() }
  let pid = process.start(process, False)

  process.send_exit(pid)

  process.sleep(1000)

  case process.is_alive(pid) {
    False -> io.println("Process is dead")
    True -> io.println("Process is alive")
  }
}
