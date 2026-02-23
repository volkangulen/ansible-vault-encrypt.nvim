if vim.g.loaded_ansible_vault_encrypt then
  return
end
vim.g.loaded_ansible_vault_encrypt = true

vim.api.nvim_create_user_command('AnsibleVaultToggle', function(opts)
  require('ansible-vault-encrypt').toggle(opts)
end, { range = true })

vim.api.nvim_create_user_command('AnsibleVaultEncrypt', function(opts)
  require('ansible-vault-encrypt').encrypt(opts)
end, { range = true })

vim.api.nvim_create_user_command('AnsibleVaultDecrypt', function(opts)
  require('ansible-vault-encrypt').decrypt(opts)
end, { range = true })

vim.keymap.set({ 'n', 'v' }, '<leader>av', ':AnsibleVaultToggle<CR>', {
  desc = 'Toggle ansible-vault encrypt/decrypt',
})
