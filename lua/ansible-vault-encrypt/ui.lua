local M = {}

function M.select_vault_id(vault_ids, callback)
  if not vault_ids or #vault_ids == 0 then
    callback(nil)
    return
  end

  if #vault_ids == 1 then
    callback(vault_ids[1])
    return
  end

  local labels = {}
  for _, vid in ipairs(vault_ids) do
    labels[#labels + 1] = vid.id
  end

  vim.ui.select(labels, { prompt = 'Select vault ID:' }, function(choice)
    if not choice then
      callback(nil)
      return
    end
    for _, vid in ipairs(vault_ids) do
      if vid.id == choice then
        callback(vid)
        return
      end
    end
    callback(nil)
  end)
end

return M
