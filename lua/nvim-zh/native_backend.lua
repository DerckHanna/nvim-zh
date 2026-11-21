local M = {}
local fs = require('nvim-zh.fs')
local paths = require('nvim-zh.paths')
local state = { active = false, status = 'idle' }
local owner, process, generation = nil, nil, 0
local vars = { 'LANG', 'LANGUAGE', 'LC_ALL', 'LC_MESSAGES', 'LOCPATH' }
local C, ffi

local function backend()
  if C then return end
  ffi = require('ffi')
  assert(ffi.os == 'Linux', '原生自动接线当前仅支持 Linux/glibc + LuaJIT')
  ffi.cdef[[
    char *bindtextdomain(const char *, const char *);
    const char *gnu_get_libc_version(void);
  ]]
  local candidate = ffi.C
  local version = ffi.string(candidate.gnu_get_libc_version())
  assert(version:match('^%d+%.%d+'), '不支持的 libc')
  C = candidate
  return version
end

local function binding()
  local value = C.bindtextdomain('nvim', nil)
  assert(value ~= nil, '无法读取 gettext 绑定')
  return ffi.string(value)
end

local function language(lang, locale_path, clear_locpath)
  local env, helplang = {}, vim.o.helplang
  for _, name in ipairs(vars) do env[name] = vim.env[name] end
  if clear_locpath then
    vim.env.LOCPATH = nil
  elseif locale_path ~= nil then
    vim.env.LOCPATH = locale_path
  end
  local ok, err = pcall(vim.cmd, 'silent language messages ' .. vim.fn.fnameescape(lang))
  for _, name in ipairs(vars) do vim.env[name] = env[name] end
  vim.o.helplang = helplang
  assert(ok, err)
end

local function restore_language(lang, locale_path)
  local ok, err = pcall(language, lang, locale_path)
  if ok then return true end
  local system_ok, system_err = pcall(language, lang, nil, true)
  if system_ok then return true end
  return nil, tostring(err) .. '；暂清 LOCPATH 后恢复仍失败：' .. tostring(system_err)
end

local function owned()
  return owner and binding() == owner.binding and vim.v.lang == owner.lang
end

local function failed_restore(reason)
  local binding_active = owner ~= nil and binding() == owner.binding
  local language_active = owner ~= nil and vim.v.lang == owner.lang
  state = { active = binding_active and language_active, status = 'restore_failed', reason = tostring(reason),
    mo_path = binding_active and owner.mo_path or nil, binding_owned = binding_active, language_owned = language_active }
end

function M.stop()
  generation = generation + 1
  if process then pcall(process.kill, process, 15); process = nil end
  local errors = {}
  if C and owner then
    local ok, err = pcall(function()
      if binding() == owner.binding then
        assert(C.bindtextdomain('nvim', owner.original_binding) ~= nil, '无法恢复 gettext 绑定')
      end
    end)
    if not ok then errors[#errors + 1] = tostring(err) end
    if vim.v.lang == owner.lang then
      local restored, why = restore_language(owner.original_lang, owner.original_locpath)
      if not restored then errors[#errors + 1] = tostring(why) end
    end
  end
  if #errors > 0 then
    local reason = table.concat(errors, '；')
    failed_restore(reason)
    return nil, reason
  end
  owner = nil
  state = { active = false, status = 'disabled' }
  return true
end

function M.start(config, resource, callback)
  generation = generation + 1
  local token = generation
  if process then pcall(process.kill, process, 15); process = nil end
  if not config.enabled or not config.apply_language then
    local stopped, err = M.stop()
    callback(not stopped and err or nil)
    return
  end
  local ok, version = pcall(backend)
  if not ok then state = { active = false, status = 'unsupported', reason = tostring(version) }; callback(); return end
  if owner and not owned() then
    state = { active = false, status = 'degraded', reason = 'external_override' }; callback(); return
  end
  local original = owner or { original_binding = binding(), original_lang = vim.v.lang,
    original_locpath = vim.env.LOCPATH }
  local old_binding, old_lang = binding(), vim.v.lang
  local old_locpath = owner and owner.locale_path or vim.env.LOCPATH
  local attempt = {}
  local locale_selected = false

  local function apply(locale_path)
    assert(C.bindtextdomain('nvim', resource.root .. '/native') ~= nil, 'gettext 绑定失败')
    attempt.binding = binding()
    local selected, select_error = pcall(language, 'zh_CN.UTF-8', locale_path)
    attempt.lang = vim.v.lang
    assert(selected, select_error)
    locale_selected = true
    local probe = resource.summary.native.probe
    assert(vim.fn.gettext(probe.msgid) == probe.msgstr, '核心译文探针失败，可能受 LANGUAGE 等环境配置影响')
    original.binding, original.lang = binding(), vim.v.lang
    original.locale_path = locale_path or vim.env.LOCPATH
    original.mo_path = resource.root .. '/native/zh_CN.UTF-8/LC_MESSAGES/nvim.mo'
    owner = original
    state = { active = true, status = 'ok', mo_path = original.mo_path, private_locale = locale_path ~= nil }
  end

  local function restore()
    local errors, external = {}, false
    local current_binding = binding()
    if attempt.binding then
      if current_binding == attempt.binding then
        if current_binding ~= old_binding then
          local ok, err = pcall(function()
            assert(C.bindtextdomain('nvim', old_binding) ~= nil, '无法恢复此前的 gettext 绑定')
          end)
          if not ok then errors[#errors + 1] = tostring(err) end
        end
      elseif current_binding ~= old_binding then
        external = true
      end
    elseif current_binding ~= old_binding then
      external = true
    end
    if attempt.lang then
      if vim.v.lang == attempt.lang then
        if vim.v.lang ~= old_lang then
          local restored, why = restore_language(old_lang, old_locpath)
          if not restored then errors[#errors + 1] = tostring(why) end
        end
      elseif vim.v.lang ~= old_lang then
        external = true
      end
    elseif vim.v.lang ~= old_lang then
      external = true
    end
    return #errors == 0, table.concat(errors, '；'), external
  end

  local function restore_failure(reason)
    failed_restore(reason)
    callback(tostring(reason))
  end

  local success, why = pcall(apply)
  if success then callback(); return end
  local restored, restore_error, external = restore()
  if external then
    state = { active = owner ~= nil, status = 'degraded', reason = 'external_override', mo_path = owner and owner.mo_path }
    callback()
    return
  end
  if not restored then restore_failure(restore_error); return end
  if locale_selected then
    state = { active = owner ~= nil, status = 'degraded', reason = tostring(why), mo_path = owner and owner.mo_path }
    callback()
    return
  end

  -- A private locale is an environment cache, never a system installation.
  local cache = paths.data() .. '/native/locales/glibc-' .. ffi.string(C.gnu_get_libc_version()) .. '-' .. ffi.arch
  local locale = cache .. '/zh_CN.UTF-8'
  if vim.uv.fs_stat(locale .. '/LC_MESSAGES') then
    success, why = pcall(apply, cache)
    if success then callback(); return end
    restored, restore_error, external = restore()
    if external then
      state = { active = owner ~= nil, status = 'degraded', reason = 'external_override', mo_path = owner and owner.mo_path }
      callback()
      return
    end
    if not restored then restore_failure(restore_error); return end
    if locale_selected then
      state = { active = owner ~= nil, status = 'degraded', reason = tostring(why), mo_path = owner and owner.mo_path }
      callback()
      return
    end
  end
  if vim.fn.executable('localedef') ~= 1 then
    state = { active = owner ~= nil, status = 'degraded', reason = tostring(why), mo_path = owner and owner.mo_path }
    callback()
    return
  end
  local staged = fs.unique(cache .. '/prepare')
  local prepared, err = pcall(fs.mkdir, staged)
  if not prepared then
    state = { active = owner ~= nil, status = 'degraded', reason = tostring(err), mo_path = owner and owner.mo_path }
    callback()
    return
  end
  state = { active = owner ~= nil, status = 'preparing', reason = '正在准备用户目录中的中文 locale',
    mo_path = owner and owner.mo_path }
  local spawned, new_process = pcall(vim.system,
    { 'localedef', '--no-archive', '-i', 'zh_CN', '-f', 'UTF-8', staged .. '/zh_CN.UTF-8' },
    { text = true, timeout = 15000 }, vim.schedule_wrap(function(result)
      if token ~= generation then vim.fn.delete(staged, 'rf'); return end
      process = nil
      local external_during_prepare = false
      local done, failure = pcall(function()
        assert(result.code == 0, (result.stderr or 'localedef failed'):sub(1, 400))
        if binding() ~= old_binding or vim.v.lang ~= old_lang then
          external_during_prepare = true
          return
        end
        local renamed = vim.uv.fs_rename(staged .. '/zh_CN.UTF-8', locale)
        assert(renamed or vim.uv.fs_stat(locale), '私有 locale 发布失败')
        apply(cache)
      end)
      vim.fn.delete(staged, 'rf')
      if external_during_prepare then
        state = { active = owner ~= nil, status = 'degraded', reason = 'external_override', mo_path = owner and owner.mo_path }
        callback()
        return
      end
      if not done then
        local ok_restore, why_restore, external_restore = restore()
        if external_restore then
          state = { active = owner ~= nil, status = 'degraded', reason = 'external_override', mo_path = owner and owner.mo_path }
          callback()
          return
        end
        if not ok_restore then restore_failure(why_restore); return end
        state = { active = owner ~= nil, status = 'degraded', reason = tostring(failure), mo_path = owner and owner.mo_path }
      end
      callback()
    end))
  if not spawned then
    vim.fn.delete(staged, 'rf')
    state = { active = owner ~= nil, status = 'degraded', reason = tostring(new_process), mo_path = owner and owner.mo_path }
    callback()
    return
  end
  process = new_process
end

function M.info() return vim.deepcopy(state) end
return M
