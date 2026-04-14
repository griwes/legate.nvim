local current = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(current, ':h')
local spec_runner = dofile(vim.fs.joinpath(vim.fs.dirname(root), 'support', 'acp', 'spec_runner.lua'))

spec_runner.run('acp chat and rendering', vim.fs.joinpath(root, 'chat_body.lua'))
