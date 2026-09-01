vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local ministry_nvim_path = vim.env.MINISTRY_NVIM_PATH
if not ministry_nvim_path or ministry_nvim_path == '' then
    error('MINISTRY_NVIM_PATH must point to a ministry.nvim checkout')
end

ministry_nvim_path = vim.fs.normalize(ministry_nvim_path)
if vim.fn.isdirectory(ministry_nvim_path) == 0 then
    error(
        string.format(
            'ministry.nvim test dependency not found at %s; set MINISTRY_NVIM_PATH to the plugin checkout',
            ministry_nvim_path
        )
    )
end

vim.opt.runtimepath:prepend(ministry_nvim_path)

local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'

if vim.fn.isdirectory(lazypath) == 0 then
    vim.fn.system({
        'git',
        'clone',
        '--filter=blob:none',
        'https://github.com/folke/lazy.nvim.git',
        '--branch=stable',
        lazypath,
    })
end

vim.opt.runtimepath:prepend(lazypath)

require('lazy').setup({
    { dir = vim.fn.getcwd(), lazy = false },
    { 'nvim-lua/plenary.nvim', lazy = false },
}, {
    root = vim.fn.stdpath('data') .. '/lazy',
    lockfile = vim.fn.stdpath('state') .. '/lazy-lock.json',
})
