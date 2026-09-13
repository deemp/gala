# GALA plugin for Claude Code

Connects [Claude Code](https://code.claude.com) to the GALA language server
(`gala lsp`), so Claude works on `.gala` files with the same type information
your editor has:

- **Diagnostics after every edit.** Parse errors, non-exhaustive matches, the
  `GALA-E*` guardrails and other transpiler errors are pushed into Claude's
  context right after it changes a file. It fixes them without waiting for a
  build.
- **Hover.** Claude can ask for the inferred type of any `val`, lambda parameter
  or expression, plus the documentation of the symbol.
- **Go to definition and find references**, across GALA packages, the Go
  standard library and third-party Go modules.

## Install

1. Install the GALA CLI and put `gala` on your `PATH`
   ([releases](https://github.com/martianoff/gala/releases)). The plugin starts
   `gala lsp`; it does not bundle the binary.
2. In Claude Code:

   ```
   /plugin marketplace add martianoff/gala
   /plugin install gala@gala
   ```

Projects created with `gala new` already contain a `.claude/settings.json` that
registers this marketplace, so Claude Code offers the plugin when you trust the
project folder. To add the same prompt to an existing project, put this in its
`.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "gala": {
      "source": { "source": "github", "repo": "martianoff/gala" }
    }
  },
  "enabledPlugins": {
    "gala@gala": true
  }
}
```

## Check that it works

Run `/plugin` and confirm `gala` is enabled with no entry in the **Errors** tab.
`Executable not found in $PATH` means `gala` is not on the `PATH` Claude Code was
started with. `claude --debug` logs the server's start-up line, which names the
GALA version and the standard library directory it resolved.

## Limits

- The server reports what the GALA transpiler detects. Errors that only the Go
  compiler finds in the generated code, such as adding a `float64` to a
  `string`, need `gala build` or `bazel build`.
- Claude receives diagnostics on the tool call after the edit, not in the edit's
  own result.
