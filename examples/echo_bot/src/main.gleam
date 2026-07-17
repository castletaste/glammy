import glammy
import gleam/io
import gleam/string

fn reply(ctx, text) -> Nil {
  case glammy.reply(ctx, text) {
    Ok(_) -> Nil
    Error(reply_error) -> io.println_error(string.inspect(reply_error))
  }
}

pub fn main() -> Nil {
  let client = glammy.api("123456:ABC-DEF...")

  let handlers =
    glammy.composer()
    |> glammy.command("start", fn(ctx) { reply(ctx, "Hi, I'm a glammy bot 👋") })
    |> glammy.hears("ping", fn(ctx) { reply(ctx, "pong") })

  case glammy.bot(client, handlers) |> glammy.start {
    Ok(_) -> Nil
    Error(start_error) -> io.println_error(string.inspect(start_error))
  }
}
