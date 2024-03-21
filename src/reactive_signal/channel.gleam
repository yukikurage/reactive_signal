import gleam/erlang/process
import gleam/erlang
import gleam/otp/actor
import gleam/dict
import gleam/list

type SubscriberMessage(s) {
  Change(s)
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
  Modify(modifier: fn(s) -> s)
  Subscribe(
    subscriber: process.Subject(SubscriberMessage(s)),
    reply_with: process.Subject(#(s, erlang.Reference)),
  )
  Unsubscribe(subscriber: erlang.Reference)
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
fn start_spec_with_trap(spec: actor.Spec(msg, s), to_msg) {
  let actor_spec =
    actor.Spec(
      init: fn() {
        process.trap_exits(True)

        case spec.init() {
          actor.Ready(state, prev_selector) -> {
            let selector =
              prev_selector
              |> process.selecting_trapped_exits(to_msg)
            actor.Ready(state, selector)
          }
          actor.Failed(str) -> actor.Failed(str)
        }
      },
      init_timeout: spec.init_timeout,
      loop: spec.loop,
    )
  actor.start_spec(actor_spec)
}

fn make_default_spec(state, loop) {
  actor.Spec(
    init: fn() { actor.Ready(state, process.new_selector()) },
    loop: loop,
    init_timeout: 5000,
  )
}

fn channel_handler(msg: ChannelMessage(s), state: ChannelActorState(s)) {
  case msg {
    Close -> {
      actor.Stop(process.Normal)
    }
    Modify(f) -> {
      let new_value = f(state.value)

      state.subscribers
      |> dict.values()
      |> list.each(fn(subscriber) {
        process.send(subscriber, Change(new_value))
      })

      actor.continue(ChannelActorState(
        value: f(state.value),
        subscribers: state.subscribers,
      ))
    }
    Subscribe(subscriber, reply_with) -> {
      let ref = erlang.make_reference()
      process.send(reply_with, #(state.value, ref))
      actor.continue(ChannelActorState(
        value: state.value,
        subscribers: state.subscribers
          |> dict.insert(ref, subscriber),
      ))
    }
    Unsubscribe(ref) -> {
      case dict.has_key(state.subscribers, ref) {
        True -> {
          actor.continue(ChannelActorState(
            value: state.value,
            subscribers: state.subscribers
              |> dict.delete(ref),
          ))
        }
        False -> {
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

fn subscriber_initializer(chn: Channel(s), new_listener) {
  // 初期化処理
  // この Actor に Channel から通知する用の Subject
  let change_subject = process.new_subject()

  case
    process.try_call(
      chn.subject,
      fn(sbj) { Subscribe(change_subject, sbj) },
      100,
    )
  {
    Ok(#(current_value, ref)) -> {
      // Listener を走らせ、Subject を取得
      let listener_wait_subject =
        start_listener_and_get_wait_subject(new_listener, current_value)

      // terminate 関数は次回更新時に呼ばれる
      let prev_listener_terminate = fn() {
        process.send(listener_wait_subject, Nil)
      }

      let unsubscribe = fn() { process.send(chn.subject, Unsubscribe(ref)) }

      let new_state =
        SubscriberActorState(
          new_listener: new_listener,
          prev_listener_terminate: prev_listener_terminate,
          unsubscribe: unsubscribe,
        )

      let new_selector =
        process.new_selector()
        |> process.selecting(change_subject, fn(s) { s })

      actor.Ready(new_state, new_selector)
    }
    Error(_) -> {
      actor.Failed("Failed to subscribe")
    }
  }
}

fn subscriber_handler(msg: SubscriberMessage(s), state: SubscriberActorState(s)) {
  case msg {
    Change(value) -> {
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
pub fn modify(channel: Channel(s), f: fn(s) -> s) -> Nil {
  actor.send(channel.subject, Modify(f))
}

/// Write value to channel
pub fn write(channel: Channel(s), s) -> Nil {
  modify(channel, fn(_) { s })
}

/// Create a new channel
pub fn new(initial_value: s) {
  let assert Ok(sbj) =
    start_spec_with_trap(
      make_default_spec(
        ChannelActorState(value: initial_value, subscribers: dict.new()),
        channel_handler,
      ),
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
  let spec =
    actor.Spec(
      init: fn() { subscriber_initializer(channel, new_subscriber) },
      loop: subscriber_handler,
      init_timeout: 5000,
    )
  // サブスクライバの作成
  let _ =
    start_spec_with_trap(
      spec,
      // Channel の親が Exit したら Channel は monitor により Terminate メッセージを受け取ることが出来る
      fn(_) { Terminate },
    )
  Nil
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
