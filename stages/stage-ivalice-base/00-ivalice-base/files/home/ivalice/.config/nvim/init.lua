-- ~/.config/nvim/init.lua — ivalice user's nvim config.
-- Offline-safe: no plugin manager, no LSP, no external downloads.

vim.opt.number = true
vim.opt.relativenumber = true

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true

vim.opt.clipboard = "unnamedplus"
vim.opt.termguicolors = true

vim.cmd("syntax on")

-- Shift-Tab outdents in insert mode.
vim.keymap.set("i", "<S-Tab>", "<C-D>")
