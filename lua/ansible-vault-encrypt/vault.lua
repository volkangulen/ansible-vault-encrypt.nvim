local M = {}

function M.is_encrypted(text)
  local trimmed = text:match('^%s*(.-)%s*$')
  if trimmed:match('!vault%s*|') then
    return true
  end
  if trimmed:match('^%$ANSIBLE_VAULT;') then
    return true
  end
  return false
end

local function strip_vault_prefix(text)
  local trimmed = text:match('^%s*(.-)%s*$')
  if trimmed:match('!vault%s*|') then
    trimmed = trimmed:gsub('^.*!vault%s*|%s*', '')
  end
  local lines = {}
  for line in trimmed:gmatch('[^\n]+') do
    lines[#lines + 1] = line:match('^%s*(.-)%s*$')
  end
  return table.concat(lines, '\n')
end

local function build_cmd(subcmd, args)
  local parts = { args.executable or 'ansible-vault', subcmd }
  for _, arg in ipairs(args.extra or {}) do
    parts[#parts + 1] = arg
  end
  return table.concat(parts, ' ')
end

function M.encrypt(text, opts)
  opts = opts or {}
  local executable = opts.executable or 'ansible-vault'

  local tmpfile = vim.fn.tempname()
  local f = io.open(tmpfile, 'w')
  if not f then
    return nil, 'Failed to create temp file'
  end
  f:write(text)
  f:close()

  local cmd = build_cmd('encrypt', {
    executable = executable,
    extra = { tmpfile },
  })

  if opts.vault_id then
    cmd = cmd .. ' --encrypt-vault-id=' .. vim.fn.shellescape(opts.vault_id)
  end

  if opts.password_file then
    cmd = cmd .. ' --vault-password-file=' .. vim.fn.shellescape(opts.password_file)
  elseif opts.vault_id and opts.vault_id_path then
    cmd = cmd .. ' --vault-id=' .. vim.fn.shellescape(opts.vault_id .. '@' .. opts.vault_id_path)
  end

  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    os.remove(tmpfile)
    return nil, output
  end

  local rf = io.open(tmpfile, 'r')
  if not rf then
    os.remove(tmpfile)
    return nil, 'Failed to read encrypted file'
  end
  local encrypted = rf:read('*a')
  rf:close()
  os.remove(tmpfile)

  return encrypted, nil
end

function M.decrypt(text, opts)
  opts = opts or {}
  local executable = opts.executable or 'ansible-vault'

  local raw = strip_vault_prefix(text)

  local tmpfile = vim.fn.tempname()
  local f = io.open(tmpfile, 'w')
  if not f then
    return nil, 'Failed to create temp file'
  end
  f:write(raw)
  f:close()

  local cmd = build_cmd('decrypt', {
    executable = executable,
    extra = { tmpfile },
  })

  if opts.password_file then
    cmd = cmd .. ' --vault-password-file=' .. vim.fn.shellescape(opts.password_file)
  elseif opts.vault_ids then
    for _, vid in ipairs(opts.vault_ids) do
      cmd = cmd .. ' --vault-id=' .. vim.fn.shellescape(vid.id .. '@' .. vid.path)
    end
  end

  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    os.remove(tmpfile)
    return nil, output
  end

  local rf = io.open(tmpfile, 'r')
  if not rf then
    os.remove(tmpfile)
    return nil, 'Failed to read decrypted file'
  end
  local decrypted = rf:read('*a')
  rf:close()
  os.remove(tmpfile)

  return decrypted, nil
end

function M.format_inline(encrypted_text)
  local lines = {}
  for line in encrypted_text:gmatch('[^\n]+') do
    lines[#lines + 1] = line
  end

  local result = { '!vault |' }
  for _, line in ipairs(lines) do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed ~= '' then
      result[#result + 1] = '  ' .. trimmed
    end
  end
  return table.concat(result, '\n')
end

return M
