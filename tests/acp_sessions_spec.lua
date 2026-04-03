local current = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(current, ':h')
local spec_runner = dofile(vim.fs.joinpath(root, 'support', 'acp', 'spec_runner.lua'))

spec_runner.run('acp sessions and persistence', vim.fs.joinpath(root, 'acp_sessions_body.lua'))
