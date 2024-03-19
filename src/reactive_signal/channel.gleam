import gleam/erlang/process
import gleam/otp/actor
import gleam/set
import gleam/list
import gleam/result

/// A message that can be sent to a channel
type ChannelMessage(s) {
  Close
  Modify(modifier: fn(s) -> s, reply_with: process.Subject(s))
  Subscribe(new_subscriber: fn(s) -> Nil)
}

type Subscription(s) {
  Subscription(new_subscriber: fn(s) -> Nil, pid: process.Pid)
}

type ChannelActorState(s) {
  ChannelActorState(value: s, subscriptions: set.Set(Subscription(s)))
}

/// A variable that can be subscribed
pub opaque type Channel(s) {
  Channel(subject: process.Subject(ChannelMessage(s)))
}

fn start_actor_with_trap(
  state: s,
  loop: fn(msg, s) -> actor.Next(msg, s),
  trap: fn(process.ExitMessage) -> msg,
) {
  let actor_spec =
    actor.Spec(
      init: fn() {
        process.trap_exits(True)
        let selector =
          process.new_selector()
          |> process.selecting_trapped_exits(trap)
        actor.Ready(state, selector)
      },
      init_timeout: 5000,
      loop: loop,
    )
  actor.start_spec(actor_spec)
}

/// Apply function to channel value
pub fn modify(channel: Channel(s), f: fn(s) -> s) -> s {
  actor.call(channel.subject, fn(sbj) { Modify(f, sbj) }, 100)
}

/// Apply function to channel value safely
pub fn try_modify(
  channel: Channel(s),
  f: fn(s) -> s,
) -> Result(s, process.CallError(s)) {
  process.try_call(channel.subject, fn(sbj) { Modify(f, sbj) }, 100)
}

/// Write value to channel
pub fn write(channel: Channel(s), s) -> Nil {
  modify(channel, fn(_) { s })
  Nil
}

/// Write value to channel safely
pub fn try_write(channel: Channel(s), s) -> Result(Nil, process.CallError(s)) {
  try_modify(channel, fn(_) { s })
  |> result.replace(Nil)
}

fn channel_handler(msg: ChannelMessage(s), state: ChannelActorState(s)) {
  case msg {
    Close -> {
      // Clean up all subscriptions
      state.subscriptions
      |> set.to_list()
      |> list.each(fn(subscription) { process.send_exit(subscription.pid) })

      actor.Stop(process.Normal)
    }
    Modify(f, reply_with) -> {
      let new_value = f(state.value)

      // Clean up all subscriptions and create new subscriptions
      let new_subscriptions =
        state.subscriptions
        |> set.to_list()
        |> list.map(fn(subscription) {
          process.send_exit(subscription.pid)

          let pid =
            process.start(
              fn() { subscription.new_subscriber(new_value) },
              False,
            )
          Subscription(subscription.new_subscriber, pid)
        })
        |> set.from_list()

      process.send(reply_with, new_value)
      actor.continue(ChannelActorState(
        value: f(state.value),
        subscriptions: new_subscriptions,
      ))
    }
    Subscribe(new_subscriber) -> {
      let pid = process.start(fn() { new_subscriber(state.value) }, False)

      let subscription = Subscription(new_subscriber, pid)

      actor.continue(ChannelActorState(
        value: state.value,
        subscriptions: state.subscriptions
          |> set.insert(subscription),
      ))
    }
  }
}

/// Create a new channel
pub fn new(initial_value: s) {
  let assert Ok(sbj) =
    start_actor_with_trap(
      ChannelActorState(value: initial_value, subscriptions: set.new()),
      channel_handler,
      // Channel の親が Exit したら Channel は trap により Close メッセージを受け取ることが出来る
      fn(_) { Close },
    )
  Channel(sbj)
}

/// Subscribe to a channel
/// Subscriber is start as a new process, and exit when the next value is published, or parent process is exit.
pub fn subscribe(channel: Channel(s), new_subscriber: fn(s) -> Nil) -> Nil {
  actor.send(channel.subject, Subscribe(new_subscriber))
}

/// Subscribe to a channel by Subject.
/// Subject will receive messages when the channel value is updated.
pub fn subscribe_from_subject(
  channel: Channel(s),
  subscriber_subject: process.Subject(s),
) -> Nil {
  subscribe(channel, fn(value) { process.send(subscriber_subject, value) })
}
