# green-harness (Claude Code plugin)

The client side of the harness: an MCP connection to your harness server, plus hooks that
forward each tool call to that server. The hooks stay silent until you attach a session.

This plugin holds no harness logic. The server keeps the rules, the journals and the checks;
the hooks pass hook events to it and return its answer (b-201).

There are two paths:

- **Local Claude Code**: the plugin below. Its hooks talk to the server directly.
- **A Claude Code cloud session** (claude.ai/code): see [Cloud](#cloud). Plugins and the
  server's domain are out of reach there, so a small hook records the session into your
  own repository, and the server reads it from GitHub.

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
are not installed there either (UNVERIFIED: from the Claude Code docs). What a cloud session
does run is the hooks committed in the repository's `.claude/settings.json` (MEASURED
2026-10-05: SessionStart, UserPromptSubmit and PostToolUse all fired).

So the cloud path has two halves, and neither calls our domain from your session:

1. **Capture** (this repository, `capture/`): a hook that appends one line per event to
   `.green-harness/capture/<session>.jsonl` in your repository. It has no harness logic and
   makes no network call.
2. **Logic** (the harness server): the model reaches it through the claude.ai connector
   with your harness key. The server reads the committed journal from GitHub through the
   harness GitHub App installed on your repository, and checks it.

You need: this public repository, your own repository, the harness connector with your key,
and the harness GitHub App on your repository. Nothing else.

**When the brief can start.** Not in the session that installs the capture: nothing of
that session is journaled, so the server refuses every changing call (nothing is changed or
recorded) until a journal of yours is verified. Commit and push the installed files, open a
NEW session, and make your first message there the task alone, exactly as you want it
recorded. The model then commits and pushes that session's journal, calls `verify_commit`,
and only then `start_project`; the task is proven by that verified prompt.

**Pending observation: how a brief runs from a cloud-only session.** Over the connector
the model starts the brief, adds its questions and tasks, reads it and asks to advance.
Each changing call (`start_project`, `next_task`, `submit_result`, `answer`, `defer`,
`advance`) runs at once, but the server records it as **pending observation**: it ran, and
nothing yet shows that a session of yours made it. It turns observed when you commit and
push the session's journal (`.green-harness/capture/`) and the model calls
`verify_commit(repo, sha)`, and that journal holds the call's PostToolUse record (the same
tool-use id, or the same input; a call with no tool-use id must carry arguments no other
call of that tool had - `next_task` and `advance` then take the `call` id the server hands
out). While any call is pending, the stage cannot move, and
`advance` is a request: the stage moves only when a verified journal shows that advance
call and nothing blocks it then. The task you typed counts only if the journal holds your
prompt equal to it, character for character. Your answers count only from a verified
dialog (the question tool), never from the model's `answer` call. A call from a client
with no capture (claude.ai chat) stays pending for good, and so does a call whose session
journal is never pushed; there is no way to release one yet (an open owner question), and a
new key does not help - the pending calls move with the project to it.

What the journal proves: an intact chain from a session start, holding the call's record,
with no shell line naming the capture files. What it does not prove: that the hook wrote
that line - a model that controls the container can append a forged record by a command
that does not name the capture files (DEBT, 2026-10-05; the chain has no key). The
assumptions this rests on (the tool-use id over the connector, PostToolUse for connector
tools in a cloud session) are UNVERIFIED: see docs/v1/UNIVERSAL.md in the harness repo.

### Install the capture (once per repository)

Ask the model in the session, in your own words, for example: "install the green-harness
capture from https://github.com/greenflac/green-harness-plugin into this repo". The steps
it should follow, which you can also run yourself:

1. Call the harness connector tool `install_instructions`. It gives your **binding**: 20
   hex characters that tie the repository to your harness account. It is not a secret.
2. Get this repository (UNVERIFIED: that a cloud session can clone a foreign public repo;
   github.com is on the default allow list per the docs):

   ```sh
   git clone --depth 1 https://github.com/greenflac/green-harness-plugin /tmp/green-harness-plugin
   ```

3. Read the two files before running anything: `green-harness/capture/install.py` and
   `green-harness/capture/capture.py`. They are short and use the Python standard library
   only.
4. Run the installer from your repository root:

   ```sh
   python3 /tmp/green-harness-plugin/green-harness/capture/install.py --repo . --binding <binding>
   ```

   It copies `capture.py` to `.claude/green-harness/capture.py`, adds four hook entries to
   `.claude/settings.json` under `"hooks"` (your own hooks stay; a second run adds nothing),
   writes `.green-harness/config.json` with the binding, and creates
   `.green-harness/capture/`. It never commits and never calls the network. A malformed
   `.claude/settings.json` (not JSON, or `"hooks"` not an object of lists) or a symbolic link
   on any path it writes stops it with exit 2, and nothing is written.
5. Review the diff and commit the line it prints. The hooks run from the next session on
   (UNVERIFIED: whether the current session picks up the new hooks).

### What is recorded

One JSON line per event: SessionStart, UserPromptSubmit, PostToolUse and
PostToolUseFailure. Each line carries the previous line's hash (`prev`) and its own
(`chain`), so an edit, a removal or a reorder shows when the server recomputes the chain.

- A prompt: only its sha256 and its length, never the text.
- A tool call: the tool name, its call id and a 16-hex digest of its input, never the
  input itself, file contents or command text.
- The answer dialog (`AskUserQuestion`): the questions, their options (UNVERIFIED: that the
  tool result carries them) and the answers you
  chose, as the tool returned them. **Warning:** text you type into that dialog as a free
  answer is committed with the journal. Do not type secrets there.

**What the harness server receives:** the whole journal file, dialog text included. It
keeps the dialog's hashes and, when an answer matches an open question, the chosen answer
as plain text in your brief.

**The hashes are not secret-proof.** They carry no salt, and your repository may be public:
anyone can hash a guess and compare. A short or guessable prompt or command (a one-word
reply, a pasted password, `cat .env`) can be confirmed that way. Do not paste secrets as
prompts in a captured session.

The chain proves order and integrity, not who wrote a line: the hook and the model run as
the same user, and a model with a shell can feed a made-up event to `capture.py` and get a
correctly chained line. A path or a command that names `green-harness/` is marked
(`touches`), except a plain `git add`/`git commit`; the server does not read a journal with
such a shell mark as your answers. Answers read from the journal are therefore the
"client-side" tier, not proof that you answered.

### Then

Commit the journal with your work as usual, and ask the model to have the harness verify
the commit (connector tool `verify_commit` with the repository and the commit sha). The
answer is one of three: fit, not fit, or unable to check, with numbers. Until the harness
GitHub App is installed on your repository, the answer is "unable to check".

### Requirements of the capture

- `python3` (MEASURED: 3.11 in one cloud container; UNVERIFIED for every container). Without
  it the hook fails with exit 127, which Claude Code does not treat as blocking
  (UNVERIFIED), the journal stays empty, and the server answers "unable to check".
- Nothing else: no `curl`, no `jq`, no network.
