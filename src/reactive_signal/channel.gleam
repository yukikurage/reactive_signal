import gleam/erlang/process
import gleam/otp/actor
import gleam/set
import gleam/list
import gleam/result
import gleam/option.{type Option}

/// A message that can be sent to a channel
type ChannelMessage(s) {
  Close
  Modify(modifier: fn(s) -> s, reply_with: process.Subject(s))
  Subscribe(new_subscriber: fn(s, process.Subject(process.Subject(Nil))) -> Nil)
}

type Subscription(s) {
  Subscription(
    new_subscriber: fn(s, process.Subject(process.Subject(Nil))) -> Nil,
    subject: Option(process.Subject(Nil)),
  )
}

type ChannelActorState(s) {
  ChannelActorState(value: s, subscriptions: set.Set(Subscription(s)))
}

/// A variable that can be subscribed
pub opaque type Channel(s) {
  Channel(subject: process.Subject(ChannelMessage(s)))
}

fn start_subscriber_and_get_subject(
  process_fn: fn(s, process.Subject(process.Subject(Nil))) -> Nil,
  initial_value: s,
  is_linked,
) -> Option(process.Subject(Nil)) {
  let subject = process.new_subject()
  let child =
    process.start(fn() { process_fn(initial_value, subject) }, is_linked)
  let monitor = process.monitor_process(child)
  let selector =
    process.new_selector()
    |> process.selecting(subject, Ok)
    |> process.selecting_process_down(monitor, Error)
  let opt_sbj =
    process.select_forever(selector)
    |> option.from_result
  process.demonitor_process(monitor)
  opt_sbj
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
      state.subscriptions
      |> set.to_list()
      |> list.each(fn(subscription) {
        subscription.subject
        |> option.map(fn(sbj) { process.send(sbj, Nil) })
      })

      actor.Stop(process.Normal)
    }
    Modify(f, reply_with) -> {
      let new_value = f(state.value)
      let new_subscriptions =
        state.subscriptions
        |> set.to_list()
        |> list.map(fn(subscription) {
          // 副作用の実行に map を使う良くない例です
          subscription.subject
          |> option.map(fn(sbj) { process.send(sbj, Nil) })

          let new_sbj =
            start_subscriber_and_get_subject(
              subscription.new_subscriber,
              new_value,
              False,
            )

          Subscription(subscription.new_subscriber, new_sbj)
        })
        |> set.from_list()

      process.send(reply_with, new_value)
      actor.continue(ChannelActorState(
        value: f(state.value),
        subscriptions: new_subscriptions,
      ))
    }
    Subscribe(new_subscriber) -> {
      let new_sbj =
        start_subscriber_and_get_subject(new_subscriber, state.value, False)

      let subscription = Subscription(new_subscriber, new_sbj)

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

/// Subscribe to a channel by function (as a subscriber process) which takes subject of subject as argument.
/// The subscriber process can catch the next value change of the channel by creating a new subject and sending it to parent process through the argument and then waiting for the creatied subject.
pub fn subscribe_with_ack(
  channel: Channel(s),
  new_subscriber: fn(s, process.Subject(process.Subject(Nil))) -> Nil,
) -> Nil {
  actor.send(channel.subject, Subscribe(new_subscriber))
}

/// Subscribe to a channel with a cleaner callback
pub fn subscribe_with_cleaner(
  channel: Channel(s),
  new_subscriber: fn(s, process.Subject(process.Subject(Nil))) -> Nil,
) -> Nil {
  actor.send(channel.subject, Subscribe(new_subscriber))
}

/// Subscribe to a channel
pub fn subscribe(channel: Channel(s), new_subscriber: fn(s) -> Nil) -> Nil {
  subscribe_with_cleaner(channel, fn(value, _) { new_subscriber(value) })
}
