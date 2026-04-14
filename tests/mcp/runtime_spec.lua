local current = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(current, ':h')
local spec_runner = dofile(vim.fs.joinpath(vim.fs.dirname(root), 'support', 'acp', 'spec_runner.lua'))

spec_runner.run('acp runtime methods and turn control', vim.fs.joinpath(root, 'runtime_body.lua'))
