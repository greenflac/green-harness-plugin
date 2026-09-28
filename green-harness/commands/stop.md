---
description: Detach the harness from this session
---
Detach the harness from this session.

Call the harness MCP tool `detach` (no arguments). The server revokes the attachment of the
session whose hook reported the call - this one, and no other - and the plugin's hook
forgets it: from the next tool call on, the harness is silent in this session again. Tell
the user what the result says: `revoked` 1, or 0 with its `why`.
