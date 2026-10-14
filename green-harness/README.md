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
2. **Write your task.** In any new session of any repository, make your message the task,
   exactly as you want it recorded.
3. **Consent.** The model asks your consent before it connects the harness. Only after you
   agree does it start the brief, from your task as you wrote it.

The model follows the server's instructions for this (UNVERIFIED that it always does: in a
real session it ignored them once and followed them once). If it does not ask, ask it in
your own words to start the green-harness brief for your task.

**Your answers.** The rule (b-363), as the server applies it: each brief question is
asked in the client's question form (`ask_owner`), and what you choose there is your answer.
When the client cannot show the form, the model asks you in chat with the same options, and
the answer it relays counts as your answer, marked "relayed by the model" in the brief,
the status and the reports; you can replace it later through the form. Moving the project
to the next stage asks for your "yes" in that form. When the client cannot show the form,
the model asks you in chat and relays your "yes"; the stage moves, marked "relayed by the
model". Whether the claude.ai client can show the form is UNVERIFIED.

The capture hook that this repository offered for the cloud before 2026-10-08 is withdrawn
(b-360): its journal had to be committed after every action. If a repository of yours
holds it, remove `.claude/green-harness/`, its four hook entries in `.claude/settings.json`,
and `.green-harness/`.
