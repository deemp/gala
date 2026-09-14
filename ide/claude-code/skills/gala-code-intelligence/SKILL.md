---
name: gala-code-intelligence
description: How to read and change GALA (.gala) code with the GALA language server. Use whenever you read, navigate, write, edit or fix .gala files — to look up inferred types and std/library signatures with the LSP tool, and to make edits in a way that returns GALA diagnostics.
---

# Working on GALA code with the language server

This plugin runs `gala lsp` for `.gala` files. GALA infers most types and has
its own standard library, so guesses about types and API names are often
wrong. The language server knows the answers. Use it.

## Edit .gala files with Edit or Write, never through the shell

Claude Code sends a file change to the language server only when it is made
with the **Edit** or **Write** tool. The server then analyzes the file, and its
diagnostics (syntax errors, non-exhaustive matches, `GALA-E*` errors) are added
to your context with the result of your next tool call.

A change made through a shell command (`cat >> file`, `sed -i`, `echo >`,
`Set-Content`, a script) is invisible to the server: no diagnostics come back,
and the server keeps analyzing stale text. For `.gala` files always use Edit or
Write, even for appends.

After an edit, read the diagnostics that arrive and fix them before moving on.
If you edit the same file again before any other tool call, the pending
diagnostics for it are discarded, so let one tool call pass (for example, a
Read of the file or an LSP hover) when you need to see them.

## Look things up with the LSP tool before guessing

The LSP tool takes a file, a 1-based line and a 1-based character on a symbol.

| You need | Operation |
|---|---|
| The inferred type of a `val`, lambda parameter or expression result | `hover` on the name |
| A function's or method's signature and documentation, including std (`Array`, `Option`, `Try`, ...) and dependencies | `hover` on a use of it |
| Where something is declared, including in std or another package | `goToDefinition` |
| Every use of a function, type or value in its package (before renaming or changing a signature) | `findReferences` |
| The declarations in a file | `documentSymbol` |
| A declaration whose file you don't know | `workspaceSymbol` with part of its name |

Prefer these over grepping for a name or reading standard library sources:
the server resolves imports, sibling files and generics the way the compiler
does, and hover shows the exact signature to call.

To learn which methods a std or dependency type offers (for example how to sort
an `Array`), do not grep or glob for its sources: they live outside the project,
often in a cache directory you may not have access to. Instead:

1. `goToDefinition` on the type name, or on a value's constructor such as
   `ArrayOf`, to get the file that declares it;
2. `documentSymbol` on that file to list the type's methods;
3. `hover` on a use of the method you pick to confirm its signature.

## Diagnostics are not a build

The server reports what the GALA transpiler checks. Errors that only the Go
compiler finds in the generated code (for example adding a `float64` to a
`string`, or a wrong argument type to a Go function) produce no diagnostic.
Before calling a change done, run `gala build` (or the project's `bazel build`
target) and fix what it reports.

If the LSP tool fails with `Command 'gala' not found`, the GALA CLI is not on
the PATH Claude Code was started with. Tell the user to install it (see
https://gala.fyi/getting-started/) and restart Claude Code; until then fall back
to reading sources and building.
