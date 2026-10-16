# green-harness-plugin

A Claude Code plugin marketplace with one plugin, `green-harness`, the open client of the
harness server. See [green-harness/README.md](green-harness/README.md).

```sh
claude plugin marketplace add greenflac/green-harness-plugin
claude plugin install green-harness@green-harness --scope user
```

In a Claude Code cloud session the plugin cannot reach the server. There, add the claude.ai
connector instead: `https://harness.greenflac.online/mcp`, signed in over OAuth with your
harness key. Then type `/green_harness_on` with your task in any session to turn the harness
on, and `/green_harness_off` to turn it off. Nothing is installed into your repository. See
[green-harness/README.md](green-harness/README.md), section Cloud.
