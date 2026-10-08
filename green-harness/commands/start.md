---
description: Attach the harness to this session only
---
Attach the harness to this session.

If the session context says this is a cloud session (b-318), do not call `attach`: tell the
user that attaching does not work there, and point to the claude.ai connector
(https://harness.greenflac.online/mcp, signed in with their harness key; the plugin README,
section Cloud). Install nothing into the user's repository (b-360).

1. Call the harness MCP tool `attach` (no arguments). Its result carries a single-use claim
   code (valid for a minute). The plugin's hook exchanges it with the server
   for this session only and keeps what it gets to itself; do not repeat the code. The server
   counts the session as attached when the first hook of this session reaches it.
2. Call the harness MCP tool `status` and tell the user what its `attach` field says. It
   should say `attached`. If it says `not attached`, say so plainly and show the user the
   status output.

Do not write any settings file: the plugin's hooks are already installed.
