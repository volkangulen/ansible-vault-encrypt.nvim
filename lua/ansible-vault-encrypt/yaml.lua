-- Minimal indentation-based walker over a block of YAML lines.
--
-- It does not parse YAML; it only groups lines into top-level entries by
-- indentation and finds "leaves" (keys whose value is a scalar, a list, or
-- any non-mapping block). Keys whose value is a nested mapping are recursed
-- into, so callers see one leaf per innermost key.

local M = {}

local KEY_PATTERN = '^(%s*)([%w_%-%.]+):(.*)$'

local function is_blank(line)
  return not line:match('%S')
end

local function is_comment(line)
  return line:match('^%s*#') ~= nil
end

local function indent_of(line)
  return #line:match('^(%s*)')
end

local function append(dst, src)
  for _, l in ipairs(src) do
    dst[#dst + 1] = l
  end
end

local function trim(s)
  return s:match('^%s*(.-)%s*$')
end

-- Split `lines` into entries at the base indentation. Every key line or
-- comment line at base indent starts a new entry; all other lines (deeper
-- lines, blank lines, stray lines) attach to the current entry.
local function parse_entries(lines)
  local base
  for _, l in ipairs(lines) do
    if not is_blank(l) then
      base = indent_of(l)
      break
    end
  end
  if not base then
    return nil
  end

  local entries = {}
  local cur
  local key_count = 0
  for _, l in ipairs(lines) do
    local at_base = not is_blank(l) and indent_of(l) == base
    local is_key = at_base and l:match(KEY_PATTERN) ~= nil
    local starts = is_key or (at_base and is_comment(l))
    if starts or not cur then
      cur = { lines = {}, is_key = is_key }
      entries[#entries + 1] = cur
      if is_key then
        key_count = key_count + 1
      end
    end
    cur.lines[#cur.lines + 1] = l
  end
  return entries, key_count, string.rep(' ', base)
end

local function all_comments(lines)
  for _, l in ipairs(lines) do
    if not is_blank(l) and not is_comment(l) then
      return false
    end
  end
  return true
end

-- Number of key entries at the top indentation level of `lines`.
function M.top_level_key_count(lines)
  local _, count = parse_entries(lines)
  return count or 0
end

-- Walk `lines`, calling `visit(leaf)` for every leaf value.
--
-- leaf.indent  indentation string of the key line ('' for a keyless block)
-- leaf.key     key name, or nil when the whole block has no keys
-- leaf.value   the value text: what follows `key:` (trimmed) plus any
--              continuation lines; a block value (list, etc.) starts with
--              '\n' followed by the raw child lines.
--
-- `visit` returns a list of replacement lines, or nil to keep the original
-- lines, or (nil, err) to abort. Returns the new lines, or (nil, err).
function M.walk(lines, visit)
  local entries, key_count, base_indent = parse_entries(lines)
  if not entries then
    return lines
  end

  if key_count == 0 then
    if all_comments(lines) then
      return lines
    end
    local body = {}
    local trailing = {}
    append(body, lines)
    while #body > 0 and is_blank(body[#body]) do
      table.insert(trailing, 1, table.remove(body))
    end
    local replacement, err = visit({ indent = base_indent, key = nil, value = table.concat(body, '\n') })
    if err then
      return nil, err
    end
    local out = {}
    append(out, replacement or body)
    append(out, trailing)
    return out
  end

  local out = {}
  for _, entry in ipairs(entries) do
    if not entry.is_key then
      append(out, entry.lines)
    else
      local first = entry.lines[1]
      local indent, key, rest = first:match(KEY_PATTERN)
      local body = {}
      for i = 2, #entry.lines do
        body[#body + 1] = entry.lines[i]
      end
      local trailing = {}
      while #body > 0 and is_blank(body[#body]) do
        table.insert(trailing, 1, table.remove(body))
      end

      local rest_trim = trim(rest)
      if rest_trim:match('^#') then
        rest_trim = ''
      end

      local replacement, err
      if rest_trim ~= '' then
        local value = rest_trim
        if #body > 0 then
          value = value .. '\n' .. table.concat(body, '\n')
        end
        replacement, err = visit({ indent = indent, key = key, value = value })
      elseif #body > 0 then
        local first_child
        for _, b in ipairs(body) do
          if not is_blank(b) and not is_comment(b) then
            first_child = b
            break
          end
        end
        if not first_child or first_child:match(KEY_PATTERN) then
          local sub
          sub, err = M.walk(body, visit)
          if sub then
            replacement = { first }
            append(replacement, sub)
          end
        else
          replacement, err = visit({ indent = indent, key = key, value = '\n' .. table.concat(body, '\n') })
        end
      end

      if err then
        return nil, err
      end
      if replacement then
        append(out, replacement)
      else
        out[#out + 1] = first
        append(out, body)
      end
      append(out, trailing)
    end
  end
  return out
end

return M
