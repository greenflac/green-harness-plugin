---
description: Attach the harness to this session only
---
Attach the harness to this session.

If the session context says the harness supports local Claude Code only (a cloud session,
b-297), tell the user that, and stop: do not call any harness tool.

1. Call the harness MCP tool `attach` (no arguments). Its result carries a single-use claim
   code (valid for a minute). The plugin's hook exchanges it with the server
   for this session only and keeps what it gets to itself; do not repeat the code. The server
   counts the session as attached when the first hook of this session reaches it.
2. Call the harness MCP tool `status` and tell the user what its `attach` field says. It
   should say `attached`. If it says `not attached`, say so plainly and show the user the
   status output.

Do not write any settings file: the plugin's hooks are already installed.
