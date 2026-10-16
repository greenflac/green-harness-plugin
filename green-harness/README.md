# green-harness (Claude Code plugin)

The client side of the harness: an MCP connection to your harness server, plus hooks that
forward each tool call to that server. The hooks stay silent until you attach a session.

This plugin holds no harness logic. The server keeps the rules, the journals and the checks;
the hooks pass hook events to it and return its answer (b-201).

There are two paths:

- **Local Claude Code**: the plugin below. Its hooks talk to the server directly.
- **A Claude Code cloud session** (claude.ai/code): see [Cloud](#cloud). Plugins and the
  server's domain are out of reach there, so the model reaches the server through the
  claude.ai connector. Nothing is installed into your repository.

## Install

```sh
claude plugin marketplace add greenflac/green-harness-plugin
claude plugin install green-harness@green-harness --scope user \
  --config "server_url=https://harness.example.com"
```

Claude Code asks for the `key` option (masked) when the plugin is enabled. You can also set it
with `/config`, or pass it with `--config key=...`; that last form leaves the key in your shell
history.

## Use

- `/green-harness:start`: attaches the harness to **this** session only. The agent gets a
  single-use claim code, and the hook exchanges it for the session's token, which only the
  hook keeps. The server confirms the attach when the first hook event carrying the token
  reaches it.
- `/green-harness:status`: shows whether this session is attached, and the project's state.
- `/green-harness:stop`: detaches this session (only this one). Its token is revoked, and
  the hooks go silent again.

When an attachment ends (8 idle hours, stopped, or replaced), the prompt and the plugin's own
commands still pass, so `/green-harness:start` always works; any other tool is blocked once
with the reason.

**In an attached session**, the forwarder fails closed: when the server does not answer
within 5 seconds, or answers anything but a JSON object, the tool call is blocked. For an
outage bypass, put `bypass=<reason>` in `~/.harness-forward.conf` (mode 600), then start
`claude` with `HARNESS_BYPASS=<the same reason>`.

A session you have not attached is untouched: every hook exits 0 at once.

## Requirements

- `curl`.
- `python3`, to read hook events and the server's answers as JSON. Without it an attached
  session is blocked; a session you have not attached is untouched.
- A POSIX `sh` at `/bin/sh`. The hook runs with a fixed `PATH`
  (`/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin`), so `curl` and `python3` must be
  there.

## Cloud

In a cloud session the network policy refuses the harness server's domain (MEASURED
2026-09-29: the session proxy answered 403), and we do not ask for an exception. Plugins
are not installed there either (UNVERIFIED: from the Claude Code docs). So in the cloud the
harness is reached only through the **claude.ai connector**: its traffic goes through
claude.ai, not through your session's network. Nothing is installed into your repository.

1. **Add the connector once.** In claude.ai, add a custom connector with the URL
   `https://harness.greenflac.online/mcp` and sign in over OAuth with your harness key.
   (MEASURED 2026-10-06: the connector signs in over OAuth on the production server, and its
   tools appear in Claude Code cloud sessions as `mcp__green-harness__*`.)
2. **Turn the harness on.** In any session of any repository, type `/green_harness_on`
   with your task after it, exactly as you want it recorded. The brief starts from that
   task. Without a task, the model asks you for it in one line. A harness key holds one
   project: if yours already has one, the model tells you its task, says the new one is
   not recorded, and continues the old project only if you say so.
3. **Turn it off.** `/green_harness_off` stops the harness: the model stops calling its
   tools and works as usual. The harness also lapses after 8 hours without a harness call.

Claude Code in the cloud sends no session id, so there the switch covers every
conversation of your key at once: an ON in one turns it on in all of them, and an OFF in
any turns it off. The command's reply says which scope it has.

The two commands are the connector's prompts. Claude Code names an MCP prompt
`/mcp__<connector>__<prompt>`, so with the connector named `green-harness` you type
`/mcp__green-harness__green_harness_on <your task>` and
`/mcp__green-harness__green_harness_off`; the slash menu lists them as
`/green-harness:green_harness_on (MCP)` and `/green-harness:green_harness_off (MCP)`, and
typing `/green_harness_on` there finds the first. UNVERIFIED until seen in a live session:
the names the menu shows, and whether a task with spaces reaches the server whole (if it is
cut, the model asks you for the task).

The command is yours: the model cannot send it. (MEASURED 2026-10-16: models in real
sessions ignored the server's instructions and never started the brief on their own.)
While the harness is off in a session, its changing tools answer "harness is off for this
session" and change nothing; `status` and `brief` still read. A local session with the
plugin's hooks needs no command.

**Your answers.** The rule (b-363), as the server applies it: each brief question is
asked in the client's question form (`ask_owner`), and what you choose there is your answer.
When the client cannot show the form, the model asks you in chat with the same options, and
the answer it relays counts as your answer, marked "relayed by the model" in the brief,
the status and the reports; you can replace it later through the form. Moving the project
to the next stage asks for your "yes" in that form. When the client cannot show the form,
the model asks you in chat and relays your "yes"; the stage moves, marked "relayed by the
model". MEASURED 2026-10-16: Claude Code cloud sessions declare the form but do not show
it. The server waits at most 40 s for a form; a form the client cancelled at its own 60 s
timeout, or never answered, counts as one it could not show, so the model then asks you in
chat. A Cancel you press yourself stays a Cancel: the question stays open.

The capture hook that this repository offered for the cloud before 2026-10-08 is withdrawn
(b-360): its journal had to be committed after every action. If a repository of yours
holds it, remove `.claude/green-harness/`, its four hook entries in `.claude/settings.json`,
and `.green-harness/`.
