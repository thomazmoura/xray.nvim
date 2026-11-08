-- Open a file or a link on the device you type on: with the desktop's default application
-- (vim.ui.open) locally, or, over SSH, through a URL served to the device at the other end
-- (see serve.lua)
local M = {}

--- Open a file or a link
---@param target string A file, or a link (https:, mailto:)
---@param opts table|nil Passed to serve.open over SSH ({ csp, message })
---@return string|nil error When no application could be started (not notified)
---@return string|nil url What was opened: the link itself, a file:// URL, or the URL serving the file
function M.open(target, opts)
  local serve = require("xray.serve")
  if serve.remote() then
    return serve.open(target, opts)
  end
  local url = target:match("^%a[%w+.-]*:") and target or vim.uri_from_fname(target)
  if not vim.ui.open then
    vim.fn.jobstart({ "xdg-open", target }, { detach = true })
    return nil, url
  end
  local _, err = vim.ui.open(target)
  if err then
    return err, nil
  end
  return nil, url
end

--- Open an HTML page in the browser, with no scripts (util.BROWSER_CSP)
---@param html string
---@return string|nil error, string|nil url
function M.html(html)
  local path = vim.fn.tempname() .. ".html"
  -- The body is UTF-8 whatever charset its own <meta> declares. Ahead of the body, the
  -- <meta> tags land in the <head> the parser opens
  local head = ('<meta charset="utf-8">\n<meta http-equiv="Content-Security-Policy" content="%s">\n'):format(
    require("xray.util").BROWSER_CSP
  )
  vim.fn.writefile(vim.split(head .. html, "\n", { plain = true }), path)
  return M.open(path)
end

-- vim.ui.open as it was before hook_ui_open
local ui_open

--- Make vim.ui.open (gx, and the plugins that call it) open on your device over SSH, as
--- M.open does; locally it stays as it was (serve.ui_open)
function M.hook_ui_open()
  if ui_open then
    return
  end
  ui_open = vim.ui.open
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.open = function(path, opt)
    if not require("xray.serve").remote() then
      return ui_open(path, opt)
    end
    -- No process to wait for: what was done is shown, as with :Xray open
    local err = M.open(path)
    return nil, err
  end
end

return M
