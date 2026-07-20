# Telegram Bot API schema baseline

`telegram-bot-api.json` is the deterministic structural snapshot used by the
drift guard. Its current baseline is Bot API 10.2, released on 14 July 2026,
and was generated directly from `https://core.telegram.org/bots/api`.

The snapshot contains only version/date, method parameters, and type fields.
Descriptions are deliberately excluded so editorial documentation changes do
not create false drift. Conversely, a clean comparison means only that the
upstream structure has not changed; it does not claim that glammy implements
every recorded method or field.

The guard does not parse prose-only constraints, method return sentences, or
union membership lists. A Bot API version/date change still fails comparison,
so release notes remain a mandatory human review step even when the tabular
inventory has no other diff.

Run the offline parser suite and live comparison:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_telegram_bot_api_schema.py'
python3 scripts/telegram_bot_api_schema.py check
```

The check exits `0` for an exact structural match, `1` for confirmed drift,
and `2` when fetching or parsing cannot produce trustworthy evidence.

After reviewing Telegram's release notes and every reported change, refresh a
baseline with explicit anti-footgun assertions:

```sh
python3 scripts/telegram_bot_api_schema.py snapshot \
  --expect-version X.Y \
  --expect-release-date YYYY-MM-DD
```

Review the generated diff. Never refresh it solely to turn CI green.
