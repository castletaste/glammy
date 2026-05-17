//// glammy — a Gleam port of grammY (the TypeScript Telegram Bot framework).
////
//// Usage outline:
////
//// ```gleam
//// import glammy/api
//// import glammy/bot
//// import glammy/composer
//// import glammy/context
////
//// pub fn main() {
////   let api = api.new("123456:ABC-DEF...")  // your bot token
////   let comp =
////     composer.new()
////     |> composer.command("start", fn(ctx) {
////       let _ = context.reply(ctx, "Hi, I'm a glammy bot!")
////       Nil
////     })
////     |> composer.hears("hello", fn(ctx) {
////       let _ = context.reply(ctx, "Hello to you too 👋")
////       Nil
////     })
////   bot.new(api, comp)
////   |> bot.start(bot.default_polling_options())
//// }
//// ```
////
//// The top-level `main` function below prints a banner — handy for
//// confirming the project builds.

import gleam/io

pub fn main() -> Nil {
  io.println("glammy — Telegram Bot framework for Gleam")
  io.println(
    "see https://github.com/grammyjs/grammY for the TypeScript original",
  )
}
