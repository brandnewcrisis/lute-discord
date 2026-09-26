# Contributing

Thanks for looking. This is a small library with strong opinions about a
few things, and they're listed here so a pull request doesn't have to
find them out through review.

## Setup

```bash
rokit install                      # the pinned lute, from rokit.toml
lute run tools/check.luau          # typecheck every file
lute lint src examples tests tools
lute run tests/run.luau            # every tests/*.test.luau, each in its own process
```

All three must be clean before a change lands. CI runs the same three
commands.

`tools/smoke.luau` runs against a real Discord server. It needs a bot
token and a channel it may post in (see `.env.example`), and it deletes
everything it creates. Run it after touching `http.luau`, `api.luau` or
multipart handling. Unit tests with a fake transport catch most things, but
not what Discord actually accepts.

## House rules

**Strict mode everywhere.** Every file starts with `--!strict`. Casting to
`any` is a last resort, and it needs a comment explaining why the precise
type can't be written. See the comments on `Payload.toJSON` and
`Client.on` for the standard to meet.

**Snowflakes are strings. Permissions are `Bitfield`s.** Never pass either
through `tonumber`. A 64-bit id loses precision as a Luau number, and the
permission mask already reaches bit 52. `Snowflake` and `Bitfield`
already do the arithmetic you'd need on strings.

**Fail at the call site.** When Discord would answer a mistake with a
generic `400 Invalid Form Body`, a builder or route should check the rule
first and raise an error that names it, with `error(message, 2)` so the
caller's line is the one reported. Most of the value of `components.luau`
and `commands.luau` is in those checks.

**Wire fields stay snake_case.** Types and payloads use Discord's own field
names (`custom_id`, `guild_id`), so the official docs can be read straight
across. Library-level options (`deleteMessageSeconds`, `ephemeral`) are
camelCase, and they're translated at one clearly marked seam.

**Comments say why.** Explain the protocol rule, the footgun, the reason
for a limit. Don't narrate what the next line does. If a Discord behaviour
surprised you, the comment is where the next person learns it.

**Tests for silent failures.** Test the code whose bugs don't throw:
arithmetic, ordering rules, state machines, limits. Use the fake transport
(`Http.new(token, { transport = fn })`) and the fake gateway socket from
`tests/fakes.luau` rather than the network.

## Adding a REST route

1. Check the route against the current
   [Discord API docs](https://discord.com/developers/docs). Don't add one
   from memory or from another library.
2. Add it to the matching `make*` factory in `src/api.luau`. The namespace
   types are derived from the factories, so there's nothing else to update.
3. Add request and response shapes to `src/types.luau`, in the section for
   objects Discord sends or bodies it accepts. Model the fields worth
   autocomplete; the types are open, so the rest stays readable.
4. Add a case to `tests/api.test.luau` asserting method, path, query and body.

## Commits and pull requests

Keep a change to one concern, and say in the description what behaviour
changes for someone using the library. Add a line to `CHANGELOG.md` under
**Unreleased** for anything a user would notice.

By contributing you agree that your work is released under the MIT licence
in `LICENSE`.
