vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local mcp_nvim_path = vim.env.MCP_NVIM_PATH
if not mcp_nvim_path or mcp_nvim_path == '' then
    mcp_nvim_path = vim.fn.fnamemodify(vim.fn.getcwd() .. '/../ministry.nvim', ':p')
end

if vim.fn.isdirectory(mcp_nvim_path) == 0 then
    error(
        string.format(
            'ministry.nvim test dependency not found at %s; set MCP_NVIM_PATH to the plugin checkout',
            mcp_nvim_path
        )
    )
end

vim.opt.runtimepath:prepend(vim.fn.fnamemodify(mcp_nvim_path, ':p'))

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
