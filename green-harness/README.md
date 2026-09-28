# green-harness (Claude Code plugin)

The client side of the harness: an MCP connection to your harness server, plus hooks that
forward each tool call to that server. The hooks stay silent until you attach a session.

This plugin holds no harness logic. The server keeps the rules, the journals and the checks;
the hooks pass hook events to it and return its answer (b-201).

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
