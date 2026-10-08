# green-harness-plugin

A Claude Code plugin marketplace with one plugin, `green-harness`, the open client of the
harness server. See [green-harness/README.md](green-harness/README.md).

```sh
claude plugin marketplace add greenflac/green-harness-plugin
claude plugin install green-harness@green-harness --scope user
```

In a Claude Code cloud session the plugin cannot reach the server. There, add the claude.ai
connector instead: `https://harness.greenflac.online/mcp`, signed in over OAuth with your
harness key. Then write your task in any session; the model asks your consent and starts the
brief. Nothing is installed into your repository. See
[green-harness/README.md](green-harness/README.md), section Cloud.
