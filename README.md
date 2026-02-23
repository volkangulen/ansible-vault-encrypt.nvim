# ansible-vault-encrypt.nvim

Encrypt and decrypt text using `ansible-vault` directly within Neovim. Supports full-file encryption, inline (visual selection) encryption, and multi-entry batch operations.

## Installation

Requires `ansible-vault` on your `$PATH` (comes with `pip install ansible`).

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
-- Zero config: works out of the box with <leader>av
{ "volkangulen/ansible-vault-encrypt.nvim" }
```

The plugin auto-discovers your `ansible.cfg` and registers commands and keybindings on load. No `setup()` call required.

## Features

- **Toggle encrypt/decrypt** with a single keybinding in normal or visual mode
- **Full-file encryption** in normal mode (produces standard `$ANSIBLE_VAULT;` format)
- **Inline encryption** in visual mode (produces YAML `!vault |` format with proper indentation)
- **Multi-entry support** -- select multiple YAML key-value pairs and encrypt/decrypt them all at once
- **Comment-aware** -- lines starting with `#` are preserved as-is during batch operations
- **Vault identity selection** -- prompted via `vim.ui.select` when multiple vault IDs are configured
- **Auto-discovers `ansible.cfg`** from `$ANSIBLE_CONFIG`, `./ansible.cfg`, `~/.ansible.cfg`, or `/etc/ansible/ansible.cfg`
- **Pin `ansible.cfg` to session** -- open an `ansible.cfg` and press `<leader>ac` to lock it in, or press from any buffer to browse for one

## Commands

| Command | Description |
|---|---|
| `:AnsibleVaultToggle` | Encrypt or decrypt (auto-detects current state) |
| `:AnsibleVaultEncrypt` | Encrypt only (warns if already encrypted) |
| `:AnsibleVaultDecrypt` | Decrypt only (warns if not encrypted) |
| `:AnsibleVaultPinCfg` | Pin an `ansible.cfg` for the session |

All encrypt/decrypt commands work in normal mode (full buffer) and with visual selections (inline).

## Default Keybinding

| Key | Mode | Action |
|---|---|---|
| `<leader>av` | Normal, Visual | `:AnsibleVaultToggle` |
| `<leader>ac` | Normal | `:AnsibleVaultPinCfg` |

## Configuration

Call `setup()` only if you need to change defaults:

```lua
{
  "volkangulen/ansible-vault-encrypt.nvim",
  opts = {
    -- Path to ansible-vault executable (default: "ansible-vault")
    executable = "ansible-vault",

    -- Keymap to toggle encrypt/decrypt (default: "<leader>av")
    -- Set to false to disable the keybinding entirely
    keymap = "<leader>av",

    -- Path to vault password file (bypasses ansible.cfg lookup)
    keyfile = nil,

    -- Path to ansible.cfg (bypasses auto-discovery)
    ansible_cfg = nil,

    -- Vault ID to use for encryption (skips the selection prompt)
    encrypt_vault_id = nil,
  },
}
```

### Custom keybinding

```lua
{ "volkangulen/ansible-vault-encrypt.nvim", opts = { keymap = "<leader>ve" } }
```

### Disable keybinding

Use commands only, no keymap registered:

```lua
{ "volkangulen/ansible-vault-encrypt.nvim", opts = { keymap = false } }
```

### Direct keyfile

Skip `ansible.cfg` entirely and point to a password file:

```lua
{ "volkangulen/ansible-vault-encrypt.nvim", opts = { keyfile = "~/.vault_pass" } }
```

### Pin vault identity

Auto-select a vault ID without prompting:

```lua
{ "volkangulen/ansible-vault-encrypt.nvim", opts = { encrypt_vault_id = "dev" } }
```

## Usage

### Encrypt/decrypt a full file

Open a YAML file and press `<leader>av` in normal mode. The entire buffer is encrypted as a standard vault file. Press again to decrypt.

### Encrypt/decrypt inline values

Visually select one or more YAML key-value lines and press `<leader>av`. Each value is encrypted individually in inline format:

```yaml
# Before
db_password: supersecret
api_key: mykey123

# After
db_password: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  3030...
api_key: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  6161...
```

Select the encrypted lines and press `<leader>av` again to decrypt them back.

### Pin ansible.cfg to session

If your project's `ansible.cfg` isn't auto-discovered (e.g. it's in a parent directory), you can pin it for the session:

- **From an `ansible.cfg` buffer**: Open the file and press `<leader>ac` -- the current buffer's path is pinned immediately.
- **From any other buffer**: Press `<leader>ac` and you'll be prompted for a path (with tab-completion).

### Mixed content

When a selection contains both encrypted and unencrypted entries, the plugin processes each independently -- encrypting only the unencrypted entries or decrypting only the encrypted ones.

## Config resolution order

1. `keyfile` option (if set, used directly)
2. `ansible_cfg` option (if set, parsed for vault config)
3. `$ANSIBLE_CONFIG` environment variable
4. `./ansible.cfg` (current directory)
5. `~/.ansible.cfg`
6. `/etc/ansible/ansible.cfg`

## License

MIT
