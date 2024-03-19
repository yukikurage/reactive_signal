import reactive_signal/channel
import gleam/erlang/process

/// Signal is read-only, but chainable Channel.
pub opaque type Signal(s) {
  Signal(subscribe: fn(fn(s) -> Nil) -> Nil)
}

pub fn from_channel(chn: channel.Channel(s)) -> Signal(s) {
  Signal(subscribe: fn(subscriber) { channel.subscribe(chn, subscriber) })
}

fn wait_trapping() {
  let selector =
    process.new_selector()
    |> process.selecting_trapped_exits(fn(_) { Nil })

  process.select_forever(selector)
}

pub fn map(sig: Signal(a), f: fn(a) -> b) -> Signal(b) {
  Signal(subscribe: fn(subscriber) { sig.subscribe(fn(x) { subscriber(f(x)) }) })
}

pub fn pure(a) -> Signal(a) {
  Signal(subscribe: fn(subscriber) { subscriber(a) })
}

pub fn chain(sig: Signal(a), f: fn(a) -> Signal(b)) -> Signal(b) {
  Signal(subscribe: fn(subscriber) {
    sig.subscribe(fn(x) { f(x).subscribe(subscriber) })
  })
}

pub fn new(init) {
  let chn = channel.new(init)
  let sig = from_channel(chn)
  #(sig, chn)
}

/// Subscribe to a channel
/// Subscriber is start as a new process, and exit when the next value is published, or parent process is exit.
pub fn subscribe(signal: Signal(s), new_subscriber: fn(s) -> Nil) -> Nil {
  signal.subscribe(new_subscriber)
}

/// Subscribe to a channel by Subject.
/// Subject will receive messages when the channel value is updated.
pub fn subscribe_from_subject(
  signal: Signal(s),
  subscriber_subject: process.Subject(s),
) -> Nil {
  subscribe(signal, fn(value) { process.send(subscriber_subject, value) })
}
