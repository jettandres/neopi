if vim.g.loaded_neopi == 1 then
  return
end
vim.g.loaded_neopi = 1

require("neopi").setup()
