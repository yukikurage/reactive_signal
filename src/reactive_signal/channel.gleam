import gleam/erlang/process
import gleam/erlang
import gleam/otp/actor
import gleam/dict
import gleam/list
import gleam/result

type SubscriberMessage(s) {
  Connect(Channel(s), reply_with: process.Subject(Nil))
  Change(s, reply_with: process.Subject(Nil))
  Terminate
}

type SubscriberActorState(s) {
  SubscriberActorState(
    new_listener: fn(s, fn() -> Nil) -> Nil,
    prev_listener_terminate: fn() -> Nil,
    unsubscribe: fn() -> Nil,
  )
}

/// A message that can be sent to a channel
type ChannelMessage(s) {
  Close
  Modify(modifier: fn(s) -> s, reply_with: process.Subject(s))
  Get(reply_with: process.Subject(s))
  Subscribe(
    subscriber: process.Subject(SubscriberMessage(s)),
    reply_with: process.Subject(erlang.Reference),
  )
  Unsubscribe(subscriber: erlang.Reference, reply_with: process.Subject(Bool))
}

type ChannelActorState(s) {
  ChannelActorState(
    value: s,
    subscribers: dict.Dict(
      erlang.Reference,
      process.Subject(SubscriberMessage(s)),
    ),
  )
}

/// A variable that can be subscribed
pub opaque type Channel(s) {
  Channel(subject: process.Subject(ChannelMessage(s)))
}

/// Actor をスタートする
/// 通常の Actor と違い、親プセスの終了を trap で捕捉し、メッセージとして受け取ることが出来る
/// チャンネル、サブスクライバの召喚に使用
fn start_actor_with_trap(
  state: s,
  loop: fn(msg, s) -> actor.Next(msg, s),
  to_msg,
) {
  let actor_spec =
    actor.Spec(
      init: fn() {
        process.trap_exits(True)
        let selector =
          process.new_selector()
          |> process.selecting_trapped_exits(to_msg)
        actor.Ready(state, selector)
      },
      init_timeout: 5000,
      loop: loop,
    )
  actor.start_spec(actor_spec)
}

fn channel_handler(msg: ChannelMessage(s), state: ChannelActorState(s)) {
  case msg {
    Close -> {
      // Clean up all subscriptions and create new subscriptions
      state.subscribers
      |> dict.values()
      |> list.each(fn(subscriber) { process.send(subscriber, Terminate) })
      actor.Stop(process.Normal)
    }
    Modify(f, reply_with) -> {
      let new_value = f(state.value)

      state.subscribers
      |> dict.values()
      |> list.each(fn(subscriber) {
        process.call(subscriber, fn(sbj) { Change(new_value, sbj) }, 5000)
      })

      process.send(reply_with, new_value)
      actor.continue(ChannelActorState(
        value: f(state.value),
        subscribers: state.subscribers,
      ))
    }
    Get(reply_with) -> {
      process.send(reply_with, state.value)
      actor.continue(state)
    }
    Subscribe(subscriber, reply_with) -> {
      let ref = erlang.make_reference()
      process.send(reply_with, ref)
      actor.continue(ChannelActorState(
        value: state.value,
        subscribers: state.subscribers
          |> dict.insert(ref, subscriber),
      ))
    }
    Unsubscribe(ref, reply_with) -> {
      case dict.has_key(state.subscribers, ref) {
        True -> {
          process.send(reply_with, True)
          actor.continue(ChannelActorState(
            value: state.value,
            subscribers: state.subscribers
              |> dict.delete(ref),
          ))
        }
        False -> {
          process.send(reply_with, False)
          actor.continue(state)
        }
      }
    }
  }
}

/// new_listener に wait_next 関数を渡して実行するための関数
/// 返り値の Subject に値を渡すと listener の wait_next が終了する
fn start_listener_and_get_wait_subject(new_listener, value) {
  // wait_next 関数を作るための listener の wrapper
  let new_listener_with_ack = fn(ack) {
    // この Subject は 次の値の更新時に呼ばれる
    let subject = process.new_subject()
    // ack を通して親に渡す -> child_subject
    process.send(ack, subject)

    // wait_next 関数を作る　subject が発火するまで待つ
    let wait_next = fn() {
      let selector =
        process.new_selector()
        |> process.selecting(subject, fn(_) { Nil })
      process.select_forever(selector)
    }
    new_listener(value, wait_next)
  }
  let ack = process.new_subject()
  // Listener プロセスの作成
  process.start(fn() { new_listener_with_ack(ack) }, False)

  // Listener プロセス内部の Subject を取得
  process.select_forever(
    process.new_selector()
    |> process.selecting(ack, fn(s) { s }),
  )
}

fn subscriber_handler(msg: SubscriberMessage(s), state: SubscriberActorState(s)) {
  case msg {
    Connect(chn, reply_with) -> {
      // 初期化処理

      // この Actor に Channel から通知する用の Subject
      let change_subject = process.new_subject()

      // 現在の Channel の値を取得しておく
      let current_value = process.call(chn.subject, Get, 5000)

      // Listener を走らせ、Subject を取得
      let listener_wait_subject =
        start_listener_and_get_wait_subject(state.new_listener, current_value)

      // terminate 関数は次回更新時に呼ばれる
      let prev_listener_terminate = fn() {
        process.send(listener_wait_subject, Nil)
      }

      // チャンネルへのサブスクライブ処理
      let ref =
        process.call(
          chn.subject,
          fn(sbj) { Subscribe(change_subject, sbj) },
          5000,
        )

      let unsubscribe = fn() {
        let _ =
          process.try_call(chn.subject, fn(sbj) { Unsubscribe(ref, sbj) }, 5000)
        Nil
      }

      let new_state =
        SubscriberActorState(
          new_listener: state.new_listener,
          prev_listener_terminate: prev_listener_terminate,
          unsubscribe: unsubscribe,
        )

      process.send(reply_with, Nil)

      // 次回以降 change_subject のイベントも受け取る
      actor.continue(new_state)
      |> actor.with_selector(
        process.new_selector()
        |> process.selecting(change_subject, fn(s) { s })
        |> process.selecting_trapped_exits(fn(_) { Terminate }),
      )
    }
    Change(value, reply_with) -> {
      // 前回の terminate を呼ぶ
      state.prev_listener_terminate()
      // Listener を走らせ、Subject を取得
      let listener_wait_subject =
        start_listener_and_get_wait_subject(state.new_listener, value)
      // terminate 関数は次回更新時に呼ばれる
      let prev_listener_terminate = fn() {
        process.send(listener_wait_subject, Nil)
      }

      let new_state =
        SubscriberActorState(
          new_listener: state.new_listener,
          prev_listener_terminate: prev_listener_terminate,
          unsubscribe: state.unsubscribe,
        )

      process.send(reply_with, Nil)
      actor.continue(new_state)
    }
    Terminate -> {
      // サブスクライバが終了するときの処理
      // まずは listener の terminate を呼ぶ
      state.prev_listener_terminate()

      // unsubscribe を呼ぶ
      state.unsubscribe()

      // 以上
      actor.Stop(process.Normal)
    }
  }
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

/// Create a new channel
pub fn new(initial_value: s) {
  let assert Ok(sbj) =
    start_actor_with_trap(
      ChannelActorState(value: initial_value, subscribers: dict.new()),
      channel_handler,
      // Channel の親が Exit したら Channel は monitor により Close メッセージを受け取ることが出来る
      fn(_) { Close },
    )
  Channel(sbj)
}

/// Subscribe to a channel
/// Subscriber is start as a new process, and exit when the next value is published, or parent process is exit.
pub fn subscribe_with_wait_next(
  channel: Channel(s),
  new_subscriber: fn(s, fn() -> Nil) -> Nil,
) -> Nil {
  // サブスクライバの作成
  let assert Ok(sbj) =
    start_actor_with_trap(
      SubscriberActorState(
        new_listener: new_subscriber,
        prev_listener_terminate: fn() { Nil },
        unsubscribe: fn() { Nil },
      ),
      subscriber_handler,
      // Channel の親が Exit したら Channel は monitor により Terminate メッセージを受け取ることが出来る
      fn(_) { Terminate },
    )
  // サブスクライバの初期化
  process.call(sbj, Connect(channel, _), 5000)
}

/// Subscribe to a channel
/// Subscriber is start as a new process, and exit when the next value is published, or parent process is exit.
pub fn subscribe(channel: Channel(s), new_subscriber: fn(s) -> Nil) -> Nil {
  subscribe_with_wait_next(channel, fn(value, _) { new_subscriber(value) })
}

/// Subscribe to a channel by Subject.
/// Subject will receive messages when the channel value is updated.
pub fn subscribe_from_subject(
  channel: Channel(s),
  subscriber_subject: process.Subject(s),
) -> Nil {
  subscribe(channel, fn(value) { process.send(subscriber_subject, value) })
}
