local M = {}

local function expand_path(path)
  if not path then
    return nil
  end
  path = path:gsub('^~', os.getenv('HOME') or '~')
  return path
end

function M.find_ansible_cfg()
  local env_cfg = os.getenv('ANSIBLE_CONFIG')
  if env_cfg then
    local f = io.open(env_cfg, 'r')
    if f then
      f:close()
      return env_cfg
    end
  end

  local candidates = {
    'ansible.cfg',
    expand_path('~/.ansible.cfg'),
    '/etc/ansible/ansible.cfg',
  }

  for _, path in ipairs(candidates) do
    local f = io.open(path, 'r')
    if f then
      f:close()
      return path
    end
  end

  return nil
end

function M.parse_cfg(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end

  local result = {}
  local in_defaults = false

  for line in f:lines() do
    local stripped = line:match('^%s*(.-)%s*$')

    if stripped:match('^%[') then
      in_defaults = stripped:lower() == '[defaults]'
    elseif in_defaults and not stripped:match('^[#;]') and stripped ~= '' then
      local key, value = stripped:match('^(%S+)%s*=%s*(.+)$')
      if key and value then
        value = value:match('^%s*(.-)%s*$')

        if key == 'vault_password_file' then
          result.password_file = expand_path(value)
        elseif key == 'vault_identity_list' then
          result.vault_ids = {}
          for entry in value:gmatch('[^,]+') do
            entry = entry:match('^%s*(.-)%s*$')
            local id, id_path = entry:match('^(.+)@(.+)$')
            if id and id_path then
              table.insert(result.vault_ids, {
                id = id,
                path = expand_path(id_path),
              })
            end
          end
          if #result.vault_ids == 0 then
            result.vault_ids = nil
          end
        end
      end
    end
  end

  f:close()
  return result
end

return M
