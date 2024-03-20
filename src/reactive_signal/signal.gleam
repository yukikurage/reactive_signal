import reactive_signal/channel
import gleam/erlang/process

/// Signal is read-only, but chainable Channel.
pub opaque type Signal(s) {
  Signal(subscribe: fn(fn(s, fn() -> Nil) -> Nil) -> Nil)
}

pub fn from_channel(chn: channel.Channel(s)) -> Signal(s) {
  Signal(subscribe: fn(subscriber) {
    channel.subscribe_with_wait_next(chn, subscriber)
  })
}

pub fn map(sig: Signal(a), f: fn(a) -> b) -> Signal(b) {
  Signal(subscribe: fn(subscriber) {
    sig.subscribe(fn(x, wait_next) { subscriber(f(x), wait_next) })
  })
}

pub fn pure(a) -> Signal(a) {
  Signal(subscribe: fn(subscriber) {
    let chn = channel.new(a)
    channel.subscribe_with_wait_next(chn, subscriber)
  })
}

pub fn chain(sig: Signal(a), f: fn(a) -> Signal(b)) -> Signal(b) {
  Signal(subscribe: fn(subscriber) {
    sig.subscribe(fn(x, wait_next) {
      f(x).subscribe(subscriber)
      wait_next()
    })
  })
}

pub fn new(init) {
  let chn = channel.new(init)
  let sig = from_channel(chn)
  #(sig, chn)
}

/// Subscribe to a channel with a wait_next function, that will wait for the next value to be published.
pub fn subscribe_with_wait_next(
  signal: Signal(s),
  new_subscriber: fn(s, fn() -> Nil) -> Nil,
) -> Nil {
  signal.subscribe(new_subscriber)
}

/// Subscribe to a channel
/// Subscriber is start as a new process, and exit when the next value is published, or parent process is exit.
pub fn subscribe(signal: Signal(s), new_subscriber: fn(s) -> Nil) -> Nil {
  signal.subscribe(fn(value, _) { new_subscriber(value) })
}

/// Subscribe to a channel by Subject.
/// Subject will receive messages when the channel value is updated.
pub fn subscribe_from_subject(
  signal: Signal(s),
  subscriber_subject: process.Subject(s),
) -> Nil {
  subscribe(signal, fn(value) { process.send(subscriber_subject, value) })
}
