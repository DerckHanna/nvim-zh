local root = vim.env.NVIM_ZH_ROOT
local index = dofile(root .. '/manifests/adapter-index.lua')
package.preload['nvim-zh.adapters.index'] = function() return index end
for id, spec in pairs(index) do
  if spec.entry then
    package.preload[spec.entry] = function()
      local instance = require('nvim-zh.plugins').managed_entry(id)
      return instance or assert(loadfile(root .. '/translations/adapters/' .. spec.entry:match('[^.]+$') .. '.lua'))(spec)
    end
  end
end
