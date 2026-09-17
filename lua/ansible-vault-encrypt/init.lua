local config = require('ansible-vault-encrypt.config')
local vault = require('ansible-vault-encrypt.vault')
local ui = require('ansible-vault-encrypt.ui')
local yaml = require('ansible-vault-encrypt.yaml')

local M = {}

M.opts = {
  executable = 'ansible-vault',
  keymap = '<leader>av',
  keyfile = nil,
  ansible_cfg = nil,
  encrypt_vault_id = nil,
}

local function get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  return {
    lines = lines,
    text = table.concat(lines, '\n'),
    start_line = start_line,
    end_line = end_line,
  }
end

local function get_buffer_text()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return {
    lines = lines,
    text = table.concat(lines, '\n'),
    start_line = 1,
    end_line = #lines,
  }
end

local function replace_lines(sel, new_lines)
  vim.api.nvim_buf_set_lines(0, sel.start_line - 1, sel.end_line, false, new_lines)
end

local function replace_text(sel, new_text)
  local new_lines = vim.split(new_text, '\n', { trimempty = false })
  -- Remove trailing empty line if present (from file read)
  if #new_lines > 1 and new_lines[#new_lines] == '' then
    table.remove(new_lines)
  end
  replace_lines(sel, new_lines)
end

local function has_unencrypted_leaf(lines)
  local found = false
  yaml.walk(lines, function(leaf)
    if not vault.is_encrypted(leaf.value) then
      found = true
    end
    return nil
  end)
  return found
end

-- Build the replacement lines for an encrypted leaf: `key: !vault |` followed
-- by the ciphertext indented two spaces deeper than the key.
local function encrypted_leaf_lines(leaf, encrypted)
  local out = vim.split(vault.format_inline(encrypted, leaf.indent .. '  '), '\n', { trimempty = false })
  out[1] = leaf.indent .. (leaf.key and (leaf.key .. ': ') or '') .. out[1]
  if leaf.comment then
    out[1] = out[1] .. ' ' .. leaf.comment
  end
  return out
end

-- Build the replacement lines for a decrypted leaf. The plaintext's first
-- line goes back after `key:`; an empty first line means the value was a
-- block (e.g. a list) and its lines follow the key line verbatim.
local function decrypted_leaf_lines(leaf, plaintext)
  -- ansible-vault round-trips bytes exactly; only drop a final newline that
  -- came from a file-based encryption, never other trailing whitespace.
  plaintext = plaintext:gsub('\n$', '')
  local plines = vim.split(plaintext, '\n', { trimempty = false })
  if not leaf.key then
    return plines
  end
  local first = table.remove(plines, 1)
  local comment = leaf.value:match('^!vault%s*|%s*(#[^\n]*)')
  local out = {}
  if leaf.value:match('^\n') and first ~= '' then
    -- Legacy layout: `key:` with `!vault |` on the next line, produced by
    -- older versions that encrypted a whole nested block under one key.
    out[1] = leaf.indent .. leaf.key .. ':'
    out[2] = leaf.indent .. '  ' .. first
  elseif first ~= '' then
    out[1] = leaf.indent .. leaf.key .. ': ' .. first
  else
    out[1] = leaf.indent .. leaf.key .. ':'
  end
  if comment then
    out[1] = out[1] .. ' ' .. comment
  end
  for _, l in ipairs(plines) do
    out[#out + 1] = l
  end
  return out
end

local function resolve_vault_config(callback)
  -- User-configured keyfile takes priority
  if M.opts.keyfile then
    callback({ password_file = M.opts.keyfile })
    return
  end

  local cfg_path = M.opts.ansible_cfg or config.find_ansible_cfg()
  if not cfg_path then
    vim.notify('No ansible.cfg found in project or default locations', vim.log.levels.ERROR)
    return
  end

  local parsed = config.parse_cfg(cfg_path)
  if not parsed then
    vim.notify('Failed to parse ansible.cfg', vim.log.levels.ERROR)
    return
  end

  if not parsed.password_file and not parsed.vault_ids then
    vim.notify('No vault_password_file or vault_identity_list in ansible.cfg', vim.log.levels.ERROR)
    return
  end

  callback(parsed)
end

local function do_encrypt(sel, is_inline)
  if vim.fn.executable(M.opts.executable) == 0 then
    vim.notify('ansible-vault not found. Install ansible.', vim.log.levels.ERROR)
    return
  end

  resolve_vault_config(function(cfg)
    local function run_encrypt(vault_id_entry)
      local encrypt_opts = {
        executable = M.opts.executable,
        password_file = cfg.password_file,
      }

      if vault_id_entry then
        encrypt_opts.vault_id = vault_id_entry.id
        encrypt_opts.vault_id_path = vault_id_entry.path
      end

      if is_inline or yaml.top_level_key_count(sel.lines) > 1 then
        -- Inline or multi-entry: encrypt each leaf value individually
        local new_lines, err = yaml.walk(sel.lines, function(leaf)
          if vault.is_encrypted(leaf.value) then
            return nil
          end
          local encrypted, enc_err = vault.encrypt(leaf.value, encrypt_opts)
          if enc_err then
            return nil, enc_err
          end
          return encrypted_leaf_lines(leaf, encrypted)
        end)
        if err then
          vim.notify('Encrypt failed: ' .. err, vim.log.levels.ERROR)
          return
        end
        replace_lines(sel, new_lines)
      else
        -- Single entry, full buffer: encrypt as whole vault file
        local result, err = vault.encrypt(sel.text, encrypt_opts)
        if err then
          vim.notify('Encrypt failed: ' .. err, vim.log.levels.ERROR)
          return
        end
        replace_text(sel, result)
      end
    end

    -- Determine vault ID (once for all entries)
    if M.opts.encrypt_vault_id and cfg.vault_ids then
      -- Find matching configured vault ID
      for _, vid in ipairs(cfg.vault_ids) do
        if vid.id == M.opts.encrypt_vault_id then
          run_encrypt(vid)
          return
        end
      end
      vim.notify('Vault ID "' .. M.opts.encrypt_vault_id .. '" not found in ansible.cfg', vim.log.levels.ERROR)
    elseif cfg.vault_ids then
      ui.select_vault_id(cfg.vault_ids, function(selected)
        if selected then
          run_encrypt(selected)
        end
      end)
    else
      run_encrypt(nil)
    end
  end)
end

local function do_decrypt(sel)
  if vim.fn.executable(M.opts.executable) == 0 then
    vim.notify('ansible-vault not found. Install ansible.', vim.log.levels.ERROR)
    return
  end

  resolve_vault_config(function(cfg)
    local decrypt_opts = {
      executable = M.opts.executable,
      password_file = cfg.password_file,
      vault_ids = cfg.vault_ids,
    }

    local new_lines, err = yaml.walk(sel.lines, function(leaf)
      if not vault.is_encrypted(leaf.value) then
        return nil
      end
      local plaintext, dec_err = vault.decrypt(leaf.value, decrypt_opts)
      if dec_err then
        return nil, dec_err
      end
      return decrypted_leaf_lines(leaf, plaintext)
    end)
    if err then
      vim.notify('Decrypt failed: ' .. err, vim.log.levels.ERROR)
      return
    end
    replace_lines(sel, new_lines)
  end)
end

local function execute(mode)
  local is_visual = mode == 'visual'
  local sel = is_visual and get_visual_selection() or get_buffer_text()

  if has_unencrypted_leaf(sel.lines) then
    if mode == 'decrypt_only' then
      vim.notify('Text is not encrypted', vim.log.levels.WARN)
      return
    end
    do_encrypt(sel, is_visual)
  else
    if mode == 'encrypt_only' then
      vim.notify('Text is already encrypted', vim.log.levels.WARN)
      return
    end
    do_decrypt(sel)
  end
end

local function detect_mode(cmd_opts)
  if cmd_opts.range > 0 then
    return 'visual'
  end
  return 'normal'
end

function M.toggle(cmd_opts)
  local mode = detect_mode(cmd_opts)
  if mode == 'visual' then
    execute('visual')
  else
    execute('normal')
  end
end

function M.encrypt(cmd_opts)
  local mode = detect_mode(cmd_opts)
  local sel = mode == 'visual' and get_visual_selection() or get_buffer_text()

  if not has_unencrypted_leaf(sel.lines) then
    vim.notify('Text is already encrypted', vim.log.levels.WARN)
    return
  end

  do_encrypt(sel, mode == 'visual')
end

function M.decrypt(cmd_opts)
  local mode = detect_mode(cmd_opts)
  local sel = mode == 'visual' and get_visual_selection() or get_buffer_text()

  if not vault.is_encrypted(sel.text) then
    vim.notify('Text is not encrypted', vim.log.levels.WARN)
    return
  end

  do_decrypt(sel)
end

function M.pin_cfg()
  local bufname = vim.fn.expand('%:t')
  if bufname == 'ansible.cfg' then
    local path = vim.fn.expand('%:p')
    M.opts.ansible_cfg = path
    vim.notify('Pinned ansible.cfg: ' .. path, vim.log.levels.INFO)
  else
    vim.ui.input({ prompt = 'Path to ansible.cfg: ', completion = 'file' }, function(input)
      if not input or input == '' then
        return
      end
      local path = vim.fn.expand(input)
      if vim.fn.filereadable(path) == 0 then
        vim.notify('File not found: ' .. path, vim.log.levels.ERROR)
        return
      end
      M.opts.ansible_cfg = path
      vim.notify('Pinned ansible.cfg: ' .. path, vim.log.levels.INFO)
    end)
  end
end

function M.setup(opts)
  M.opts = vim.tbl_deep_extend('force', M.opts, opts or {})

  -- Remove default keymap and set custom one if user provided a different keymap
  if M.opts.keymap and M.opts.keymap ~= '<leader>av' then
    pcall(vim.keymap.del, { 'n', 'v' }, '<leader>av')
    vim.keymap.set({ 'n', 'v' }, M.opts.keymap, ':AnsibleVaultToggle<CR>', {
      desc = 'Toggle ansible-vault encrypt/decrypt',
    })
  elseif M.opts.keymap == false then
    pcall(vim.keymap.del, { 'n', 'v' }, '<leader>av')
  end
end

return M
