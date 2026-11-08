-- xray.nvim: what a buffer links to, shown and handed to the device you type on.
--   - preview.lua: image previews in the terminal (Kitty graphics, Sixel or half-blocks)
--   - richcopy.lua: Markdown copied as rich text (text/html), to paste in Teams and others
--   - open.lua, serve.lua: files and links opened on the device at the other end of SSH
--   - client.lua: that device, and the sockets its ssh forwards back
-- No keymaps: map the functions (see the README).
local M = {}

local defaults = {
  -- Image previews in the terminal (see preview.lua)
  preview = {
    -- "auto": the Kitty graphics protocol where the terminal has it, else Sixel, else
    -- half-blocks (▀, any true-color terminal). Or always one of "kitty", "sixel", "blocks"
    -- (behind a tmux on another machine, from $TMUX_CLIENT_TERMINAL: see the README)
    protocol = "auto",
    -- Turn previews on as soon as a Markdown file opens (and the buffers of plugins that
    -- attach their own, see preview.attach). toggle_current() in any other buffer switches
    -- this on and off for the session
    auto = false,
    -- Web images (https://) shown from these domains and their subdomains, e.g.
    -- { "example.com" } (www.example.com too): any other web image is never fetched
    safe_domains = {},
  },

  -- Copying Markdown as rich text (see richcopy.lua)
  richcopy = {
    -- Socket that hands the HTML to the clipboard of the PC you ssh from, forwarded by its
    -- ssh to bin/xray-richcopy-listen (see the README). nil: /tmp/xray-richcopy-<user>.sock
    socket = nil,
  },

  -- Opening files and links on another device over SSH (see serve.lua)
  serve = {
    -- "auto": as URLs when attached over SSH; "url": always; "local": never (vim.ui.open)
    mode = "auto",
    -- Port the URLs are served from; forward it with ssh -L
    port = 8484,
    -- Host the URLs name (nil: localhost): the name your device reaches this machine by,
    -- e.g. "dev.internal" (fallback: $XRAY_SERVE_HOST). Only on the machine it resolves to
    -- (or with bind set): elsewhere the URLs stay localhost
    host = nil,
    -- Address listened on (nil: the one host resolves to on this machine, else 127.0.0.1,
    -- reached through ssh -L). "0.0.0.0" for all of them (fallback: $XRAY_SERVE_BIND)
    bind = nil,
    -- Copy each URL: with Termux in front, to the phone through termux_socket (forwarded to
    -- termux-clipboard-set, see the README), else to the + register (OSC 52 reaches the SSH
    -- client's clipboard)
    clipboard = true,
    -- nil: /tmp/termux-clipboard-<user>-set.sock
    termux_socket = nil,
    -- Socket that opens each URL in the browser of the device you type on, forwarded by its
    -- ssh to bin/xray-open-listen (PC) or termux-open-url (Termux), see the README.
    -- nil: /tmp/xray-open-<user>.sock
    open_socket = nil,
    -- The same, forwarded by the phone's ssh (Termux), tried first with Termux in front:
    -- the PC's and the phone's connections each forward their own.
    -- nil: /tmp/xray-open-termux-<user>.sock
    termux_open_socket = nil,
    -- Over SSH, vim.ui.open (gx, and the plugins that call it) opens on your device as
    -- :Xray open does, links to localhost rewritten (see localhost below). Locally, unchanged
    ui_open = false,
    -- Name that replaces localhost (127.0.0.1, [::1]) in the http(s) links opened over SSH,
    -- where the device cannot reach this machine's localhost, e.g. "dev.internal"
    -- (fallback: $XRAY_SERVE_LOCALHOST, then host)
    localhost = nil,
  },
}

local config

--- Fill in what is left unset from the environment
local function env_fallbacks()
  if config.serve.host == nil and (vim.env.XRAY_SERVE_HOST or "") ~= "" then
    config.serve.host = vim.env.XRAY_SERVE_HOST
  end
  if config.serve.bind == nil and (vim.env.XRAY_SERVE_BIND or "") ~= "" then
    config.serve.bind = vim.env.XRAY_SERVE_BIND
  end
  if config.serve.localhost == nil and (vim.env.XRAY_SERVE_LOCALHOST or "") ~= "" then
    config.serve.localhost = vim.env.XRAY_SERVE_LOCALHOST
  end
end

--- Problems with the configuration, one message each
---@return table
local function problems()
  local errors = {}
  local preview, serve = config.preview, config.serve
  if not vim.tbl_contains({ "auto", "kitty", "sixel", "blocks" }, preview.protocol) then
    table.insert(errors, 'preview.protocol must be "auto", "kitty", "sixel" or "blocks"')
  end
  if type(preview.auto) ~= "boolean" then
    table.insert(errors, "preview.auto must be true or false")
  end
  local safe_domains = preview.safe_domains
  if not (vim.islist(safe_domains) and vim.iter(safe_domains):all(function(domain)
    return type(domain) == "string" and domain ~= ""
  end)) then
    table.insert(errors, 'preview.safe_domains must be a list of domains, e.g. { "example.com" }')
  end
  if not vim.tbl_contains({ "auto", "url", "local" }, serve.mode) then
    table.insert(errors, 'serve.mode must be "auto", "url" or "local"')
  end
  if type(serve.ui_open) ~= "boolean" then
    table.insert(errors, "serve.ui_open must be true or false")
  end
  if type(serve.port) ~= "number" then
    table.insert(errors, "serve.port must be a number")
  end
  for _, key in ipairs({ "host", "bind", "termux_socket", "open_socket", "termux_open_socket", "localhost" }) do
    if serve[key] ~= nil and type(serve[key]) ~= "string" then
      table.insert(errors, ("serve.%s must be a string"):format(key))
    end
  end
  if config.richcopy.socket ~= nil and type(config.richcopy.socket) ~= "string" then
    table.insert(errors, "richcopy.socket must be a string")
  end
  return errors
end

--- Configure xray. Each call merges into the configuration so far: a plugin depending on
--- xray can pass options on, and yours still apply
---@param opts table|nil
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config or vim.deepcopy(defaults), opts or {})
  env_fallbacks()
  local errors = problems()
  if #errors > 0 then
    vim.notify("[xray] " .. table.concat(errors, "\n[xray] "), vim.log.levels.ERROR)
  end
  if config.serve.ui_open == true then
    require("xray.open").hook_ui_open()
  end
end

--- Current configuration (the defaults until setup)
---@return table
function M.config()
  if not config then
    M.setup()
  end
  return config
end

return M
