# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Neovim plugin (Lua) that encrypts/decrypts text using `ansible-vault` directly within the editor. Supports both full-file and visual-selection (inline) encrypt/decrypt, with vault identity selection via `vim.ui.select`.

## Architecture

Five modules under `lua/ansible-vault-encrypt/`:

- **init.lua** — Plugin entry point and public API. Exports `setup(opts)`, `toggle()`, `encrypt()`, `decrypt()`. Handles visual selection vs full-buffer detection, orchestrates config resolution → vault operation → buffer replacement. Defines default options and sets up keymaps.
- **yaml.lua** — Indentation-based walker over a block of YAML lines (no real YAML parsing). `walk(lines, visit)` groups lines into entries at the base indent, recurses into keys whose value is a nested mapping, and calls `visit(leaf)` once per innermost value. A leaf is `{ indent, key, value }`; a block value (list, etc.) is passed as `'\n'` followed by the raw child lines. `visit` returns replacement lines or nil to keep the original. Comments and blank lines pass through untouched.
- **config.lua** — Finds and parses `ansible.cfg`. Searches `$ANSIBLE_CONFIG`, then `./ansible.cfg`, `~/.ansible.cfg`, `/etc/ansible/ansible.cfg`. Extracts `vault_password_file` and `vault_identity_list` from the `[defaults]` section.
- **vault.lua** — Wraps the `ansible-vault` CLI. Encrypt/decrypt work via temp files (`vim.fn.tempname()`). Detects encrypted text by checking for `!vault |` (inline YAML) or `$ANSIBLE_VAULT;` header. `format_inline()` converts full vault output to YAML inline format (`!vault |` with 2-space indented lines).
- **ui.lua** — Thin wrapper around `vim.ui.select` for choosing a vault ID when multiple identities exist. Auto-selects if only one ID is configured.

`plugin/ansible-vault-encrypt.lua` registers the three user commands (`AnsibleVaultToggle`, `AnsibleVaultEncrypt`, `AnsibleVaultDecrypt`) with `{ range = true }`.

## Key Design Details

- **Inline vs full-file encryption**: Visual selection triggers inline format (`!vault |` prefix + indented ciphertext). Normal mode encrypts the entire buffer as a standard vault file (`$ANSIBLE_VAULT;` header) when it has a single top-level key; with several top-level keys it falls back to per-leaf inline encryption.
- **Nested mappings**: Inline mode encrypts each innermost scalar separately (`prop: !vault |`). Lists and other non-mapping blocks are encrypted as one value under their key, stored with a leading newline so decrypt can put the block back under `key:`. Decrypt also recognises the legacy layout (`key:` followed by `!vault |` on the next line) produced before nested support existed.
- **Config resolution priority**: `opts.keyfile` (user-supplied) → `opts.ansible_cfg` (user-supplied path) → auto-discovered `ansible.cfg` → error.
- **Vault ID flow**: If `opts.encrypt_vault_id` is set, it's matched against parsed `vault_identity_list`. Otherwise, user is prompted via `vim.ui.select`. Decryption passes all known vault IDs to try them.
- **CLI interaction**: All vault operations are synchronous via `vim.fn.system()`.

## Development

No build step or linter is configured. Integration tests run the real plugin against `ansible-vault` in headless Neovim:

```bash
nvim --headless -u NONE --cmd "set rtp+=." -l tests/run.lua
```

Each case prints `PASS`/`FAIL`; the exit code is non-zero on any failure. Add new cases to `tests/run.lua`.

To test manually, open Neovim with the plugin loaded:

```bash
nvim --cmd "set rtp+=$(pwd)" <test-yaml-file>
```

Then call `:AnsibleVaultToggle`, `:AnsibleVaultEncrypt`, or `:AnsibleVaultDecrypt` (with or without visual selection). Requires `ansible-vault` on `$PATH` and a valid `ansible.cfg` or keyfile.
