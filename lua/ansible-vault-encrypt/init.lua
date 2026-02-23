local config = require('ansible-vault-encrypt.config')
local vault = require('ansible-vault-encrypt.vault')
local ui = require('ansible-vault-encrypt.ui')

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
    text = table.concat(lines, '\n'),
    start_line = start_line,
    end_line = end_line,
  }
end

local function get_buffer_text()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return {
    text = table.concat(lines, '\n'),
    start_line = 1,
    end_line = #lines,
  }
end

local function replace_text(sel, new_text)
  local new_lines = vim.split(new_text, '\n', { trimempty = false })
  -- Remove trailing empty line if present (from file read)
  if #new_lines > 1 and new_lines[#new_lines] == '' then
    table.remove(new_lines)
  end
  vim.api.nvim_buf_set_lines(0, sel.start_line - 1, sel.end_line, false, new_lines)
end

local function split_yaml_entries(text)
  -- Single vault file (full-file encryption) — return as one entry
  local trimmed = text:match('^%s*(.-)%s*$')
  if trimmed:match('^%$ANSIBLE_VAULT;') then
    return { text }
  end

  local lines = vim.split(text, '\n', { trimempty = false })

  -- Find the base indentation from first non-blank line
  local base_indent
  for _, line in ipairs(lines) do
    if line:match('%S') then
      base_indent = line:match('^(%s*)')
      break
    end
  end
  if not base_indent then
    return { text }
  end

  local entries = {}
  local current = {}
  local current_has_key = false

  for _, line in ipairs(lines) do
    local indent = line:match('^(%s*)')
    local is_key = line:match('%S') and indent == base_indent and line:match('^%s*[%w_%-%.]+:%s')
    local is_comment = line:match('%S') and indent == base_indent and line:match('^%s*#')
    local is_boundary = is_key or (is_comment and current_has_key)
    if is_boundary and #current > 0 then
      -- Trim trailing blank lines from previous entry
      while #current > 0 and current[#current] == '' do
        table.remove(current)
      end
      if #current > 0 then
        entries[#entries + 1] = table.concat(current, '\n')
      end
      current = { line }
      current_has_key = is_key
    elseif #current > 0 or line:match('%S') then
      current[#current + 1] = line
      if is_key then current_has_key = true end
    end
  end

  -- Last entry
  while #current > 0 and current[#current] == '' do
    table.remove(current)
  end
  if #current > 0 then
    entries[#entries + 1] = table.concat(current, '\n')
  end

  if #entries == 0 then
    return { text }
  end

  return entries
end

local function is_comment_block(text)
  for line in text:gmatch('[^\n]+') do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed ~= '' and not trimmed:match('^#') then
      return false
    end
  end
  return true
end

local function has_unencrypted_entry(text)
  local entries = split_yaml_entries(text)
  for _, entry in ipairs(entries) do
    if not vault.is_encrypted(entry) and not is_comment_block(entry) then
      return true
    end
  end
  return false
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

      local entries = split_yaml_entries(sel.text)

      if #entries > 1 or is_inline then
        -- Multi-entry or inline: process each entry individually
        local results = {}
        for _, entry in ipairs(entries) do
          if vault.is_encrypted(entry) or is_comment_block(entry) then
            results[#results + 1] = entry
          else
            local yaml_prefix, text_to_encrypt = vault.extract_yaml_key(entry)
            local result, err = vault.encrypt(text_to_encrypt, encrypt_opts)
            if err then
              vim.notify('Encrypt failed: ' .. err, vim.log.levels.ERROR)
              return
            end
            if yaml_prefix then
              local base_indent = yaml_prefix:match('^(%s*)') or ''
              result = yaml_prefix .. vault.format_inline(result, base_indent .. '  ')
            else
              result = vault.format_inline(result)
            end
            results[#results + 1] = result
          end
        end
        replace_text(sel, table.concat(results, '\n\n'))
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

    local entries = split_yaml_entries(sel.text)
    local results = {}

    for _, entry in ipairs(entries) do
      if not vault.is_encrypted(entry) then
        results[#results + 1] = entry
      else
        local yaml_prefix, vault_text = vault.extract_yaml_key(entry)
        local result, err = vault.decrypt(vault_text, decrypt_opts)
        if err then
          vim.notify('Decrypt failed: ' .. err, vim.log.levels.ERROR)
          return
        end
        if yaml_prefix then
          result = result:gsub('%s+$', '')
          result = yaml_prefix .. result
        end
        results[#results + 1] = result
      end
    end

    replace_text(sel, table.concat(results, '\n\n'))
  end)
end

local function execute(mode)
  local is_visual = mode == 'visual'
  local sel = is_visual and get_visual_selection() or get_buffer_text()

  if has_unencrypted_entry(sel.text) then
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

  if not has_unencrypted_entry(sel.text) then
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
