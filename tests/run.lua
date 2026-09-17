-- Headless integration tests. Run from repo root:
--   nvim --headless -u NONE --cmd "set rtp+=." -l tests/run.lua
-- Requires `ansible-vault` on $PATH.

local keyfile = vim.fn.tempname()
local kf = assert(io.open(keyfile, 'w'))
kf:write('test-password\n')
kf:close()

local avc = require('ansible-vault-encrypt')
avc.setup({ keyfile = keyfile })

local failures = 0

local function set_buffer(lines)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

local function select_lines(first, last)
  vim.api.nvim_buf_set_mark(0, '<', first, 0, {})
  vim.api.nvim_buf_set_mark(0, '>', last, 0, {})
end

local function lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function check(name, cond, detail)
  if cond then
    print('PASS ' .. name)
  else
    failures = failures + 1
    print('FAIL ' .. name .. (detail and ('\n  ' .. detail) or ''))
  end
end

local function dump(ls)
  return table.concat(ls, '\n')
end

local function is_cipher_line(line, indent)
  return line:match('^' .. indent .. '[%$%x]') ~= nil and line:match('^' .. indent .. '%S') ~= nil
end

-- Test 1: nested mapping encrypts each leaf individually
do
  local original = {
    'vault_key1:',
    '  prop1: 123',
    '  prop2: abc',
  }
  set_buffer(original)
  select_lines(1, 3)
  avc.encrypt({ range = 2 })
  local out = lines()

  check('nested: parent key line kept as-is', out[1] == 'vault_key1:', dump(out))

  local prop1_idx, prop2_idx
  for i, l in ipairs(out) do
    if l == '  prop1: !vault |' then prop1_idx = i end
    if l == '  prop2: !vault |' then prop2_idx = i end
  end
  check('nested: prop1 became inline vault', prop1_idx ~= nil, dump(out))
  check('nested: prop2 became inline vault', prop2_idx ~= nil, dump(out))
  if prop1_idx then
    check('nested: prop1 ciphertext indented 4 spaces',
      out[prop1_idx + 1] and out[prop1_idx + 1]:match('^    %$ANSIBLE_VAULT;') ~= nil, dump(out))
  end
  check('nested: parent was not encrypted as a blob', not dump(out):match('vault_key1:%s*!vault'), dump(out))

  -- Round trip
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('nested: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 2: deeper nesting recurses until leaves
do
  local original = {
    'a:',
    '  b:',
    '    c: 1',
    '    d: two',
    '  e: three',
  }
  set_buffer(original)
  select_lines(1, 5)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('deep: a and b unchanged', out[1] == 'a:' and out[2] == '  b:', dump(out))
  check('deep: c is leaf vault', dump(out):match('\n    c: !vault |\n      %$ANSIBLE_VAULT;') ~= nil, dump(out))
  check('deep: d is leaf vault', dump(out):match('\n    d: !vault |\n') ~= nil, dump(out))
  check('deep: e is leaf vault', dump(out):match('\n  e: !vault |\n    %$ANSIBLE_VAULT;') ~= nil, dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('deep: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 3: list value is encrypted as one blob, not recursed
do
  local original = {
    'items:',
    '  - a',
    '  - b',
  }
  set_buffer(original)
  select_lines(1, 3)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('list: encrypted as single value under key', out[1] == 'items: !vault |', dump(out))
  check('list: ciphertext indented 2 spaces', out[2] and out[2]:match('^  %$ANSIBLE_VAULT;') ~= nil, dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('list: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 4: flat selection still works (regression)
do
  local original = { 'x: 1', 'y: two' }
  set_buffer(original)
  select_lines(1, 2)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('flat: x vault', out[1] == 'x: !vault |', dump(out))
  check('flat: y vault', dump(out):match('\ny: !vault |\n') ~= nil, dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('flat: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 5: already-encrypted leaf inside nested mapping is left alone, others encrypted
do
  set_buffer({ 'p:', '  q: 1' })
  select_lines(1, 2)
  avc.encrypt({ range = 2 })
  local after_first = lines()
  after_first[#after_first + 1] = '  r: 2'
  set_buffer(after_first)
  select_lines(1, #after_first)
  avc.encrypt({ range = 2 })
  local out = lines()
  local q_count = select(2, dump(out):gsub('  q: !vault |', ''))
  check('mixed: q still single vault', q_count == 1, dump(out))
  check('mixed: r now vault', dump(out):match('\n  r: !vault |\n') ~= nil, dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('mixed: decrypt restores all', dump(lines()) == 'p:\n  q: 1\n  r: 2', dump(lines()))
end

-- Test 6: comments, blank lines and trailing spaces on the parent key are preserved
do
  local original = {
    '# top comment',
    'parent:   ',
    '  # inner comment',
    '  one: 1',
    '',
    '  two: 2',
    '',
    'other: 3',
  }
  set_buffer(original)
  select_lines(1, #original)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('layout: top comment kept', out[1] == '# top comment', dump(out))
  check('layout: parent key line kept verbatim', out[2] == 'parent:   ', dump(out))
  check('layout: inner comment kept', out[3] == '  # inner comment', dump(out))
  check('layout: one is vault', out[4] == '  one: !vault |', dump(out))
  check('layout: blank line before two kept', dump(out):match('\n\n  two: !vault |\n') ~= nil, dump(out))
  check('layout: blank line before other kept', dump(out):match('\n\nother: !vault |\n') ~= nil, dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('layout: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 7: block scalar value round-trips
do
  local original = { 'cert: |', '  line one', '  line two' }
  set_buffer(original)
  select_lines(1, 3)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('block scalar: single vault under key', out[1] == 'cert: !vault |' and #out > 2, dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('block scalar: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 8: keyless selection (bare value) becomes a bare inline vault and back
do
  local original = { 'just a secret' }
  set_buffer(original)
  select_lines(1, 1)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('keyless: bare inline vault', out[1] == '!vault |' and out[2]:match('^  %$ANSIBLE_VAULT;') ~= nil, dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('keyless: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 9: normal mode on a single top-level key encrypts the whole buffer as a vault file
do
  local original = { 'vault_key1:', '  prop1: 123', '  prop2: abc' }
  set_buffer(original)
  avc.encrypt({ range = 0 })
  local out = lines()
  check('normal mode: whole-file vault header', out[1]:match('^%$ANSIBLE_VAULT;') ~= nil, dump(out))
  avc.decrypt({ range = 0 })
  check('normal mode: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 10: legacy blob layout (`key:` then `!vault |` on the next line) still decrypts
do
  -- Build what the old code produced: the nested block encrypted as one value
  -- with the first line's indentation stripped.
  local tmp = vim.fn.tempname()
  local f = assert(io.open(tmp, 'w'))
  f:write('prop1: 123\n  prop2: abc')
  f:close()
  vim.fn.system('ansible-vault encrypt --vault-password-file=' .. vim.fn.shellescape(keyfile) .. ' ' .. vim.fn.shellescape(tmp))
  local legacy = { 'vault_key1:', '  !vault |' }
  for line in io.lines(tmp) do
    if line:match('%S') then legacy[#legacy + 1] = '  ' .. line end
  end
  os.remove(tmp)
  set_buffer(legacy)
  select_lines(1, #legacy)
  avc.decrypt({ range = 2 })
  check('legacy: decrypts to nested mapping', dump(lines()) == 'vault_key1:\n  prop1: 123\n  prop2: abc', dump(lines()))
end

-- Test 11: a keyless scalar containing a colon is not mistaken for a key
do
  local original = { 'https://secret' }
  set_buffer(original)
  select_lines(1, 1)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('colon: bare inline vault, not a key', out[1] == '!vault |', dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('colon: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 12: inline comment on a block value's key line survives the round trip
do
  local original = { 'ports: # note', '  - 1', '  - 2' }
  set_buffer(original)
  select_lines(1, 3)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('header comment: kept on vault line', out[1] == 'ports: !vault | # note', dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('header comment: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 13: trailing spaces inside a block scalar are not trimmed on decrypt
do
  local original = { 'cert: |', '  line  ' }
  set_buffer(original)
  select_lines(1, 2)
  avc.encrypt({ range = 2 })
  local out = lines()
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('trailing spaces: decrypt is lossless', dump(lines()) == dump(original), dump(lines()))
end

-- Test 14: keyless selection with a leading comment keeps the comment outside the value
do
  local original = { '# note', 'secret' }
  set_buffer(original)
  select_lines(1, 2)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('keyless comment: comment kept', out[1] == '# note' and out[2] == '!vault |', dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('keyless comment: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 15: a comment indented differently from the keys does not set the base indent
do
  local original = { '  # note', 'secret: value' }
  set_buffer(original)
  select_lines(1, 2)
  avc.encrypt({ range = 2 })
  local out = lines()
  check('comment indent: key recognised', out[1] == '  # note' and out[2] == 'secret: !vault |', dump(out))
  select_lines(1, #out)
  avc.decrypt({ range = 2 })
  check('comment indent: decrypt restores original', dump(lines()) == dump(original), dump(lines()))
end

-- Test 16: one-byte values encrypt even when the system `shred` fails.
-- ansible-vault's fallback shredder divides by a random chunk length that can
-- be zero for a 1-byte file, so the plugin must never let it shred plaintext.
do
  local fakebin = vim.fn.tempname()
  vim.fn.mkdir(fakebin, 'p')
  local sh = assert(io.open(fakebin .. '/shred', 'w'))
  sh:write('#!/bin/sh\nexit 1\n')
  sh:close()
  vim.fn.setfperm(fakebin .. '/shred', 'rwxr-xr-x')
  local saved_path = vim.env.PATH
  vim.env.PATH = fakebin .. ':' .. saved_path

  local original = { 'shares: 5', 'threshold: 3' }
  local failed = 0
  for _ = 1, 10 do
    set_buffer(original)
    select_lines(1, 2)
    avc.encrypt({ range = 2 })
    local out = lines()
    if out[1] ~= 'shares: !vault |' or not dump(out):match('\nthreshold: !vault |\n') then
      failed = failed + 1
    end
  end
  check('one-byte values: encrypt with failing shred', failed == 0, failed .. '/10 attempts failed')

  vim.env.PATH = saved_path
  vim.fn.delete(fakebin, 'rf')
end

os.remove(keyfile)
if failures > 0 then
  print(failures .. ' failure(s)')
  vim.cmd('cquit! 1')
else
  print('all passed')
  vim.cmd('quit!')
end
