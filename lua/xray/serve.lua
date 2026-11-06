-- Opening files on another device when Neovim runs over SSH (a phone in Termux, a
-- tablet…): there is no display on this end, so open.lua hands each file to
-- a small HTTP server inside Neovim instead of vim.ui.open, and shows its URL, copied to
-- the clipboard (the phone's through serve.termux_socket with Termux in front, else the +
-- register, which OSC 52 takes to the SSH client's). By default the server listens on
-- 127.0.0.1 only, reached through the SSH connection itself (ssh -L 8484:localhost:8484):
-- nothing is open on the network. serve.bind and serve.host open it to a private network
-- instead (Tailscale…). Each file gets a URL of its own with 128 random bits in it, as the
-- other users of this machine (or that network) can connect too. URLs work until Neovim exits.
local M = {}

local function options()
  return require("xray").config().serve
end

-- Longest request head read (bytes): a browser's request line and headers fit easily
local MAX_HEAD = 8192

-- Content type of the files served, by extension: images get the extension of the format
-- found in their content, when the caller named them so). Anything else is downloaded,
-- never shown
local TYPES = {
  png = "image/png",
  jpg = "image/jpeg",
  gif = "image/gif",
  bmp = "image/bmp",
  tiff = "image/tiff",
  webp = "image/webp",
  html = "text/html; charset=utf-8",
  pdf = "application/pdf",
  txt = "text/plain; charset=utf-8",
  csv = "text/plain; charset=utf-8",
  md = "text/plain; charset=utf-8",
  log = "text/plain; charset=utf-8",
}

-- Files served: token -> path, and path -> token (a file opened again keeps its URL)
local files, tokens = {}, {}

-- Policy of the HTML pages that run a script of their own (richcopy's copy page): token -> CSP
local policies = {}

-- Listening TCP handle, once started, and the port it listens on
local server, port

-- Policy of the HTML pages served, sent as a header too (util.BROWSER_CSP)
local csp

--- Whether files are opened as URLs: always, never, or ("auto") when the client attached
--- now came over SSH. Inside tmux, its environment tells (updated on every attach, so a
--- Neovim started from the desktop still serves once you attach over SSH, and the other
--- way round); outside, Neovim's own
---@return boolean
function M.remote()
  local mode = options().mode
  if mode ~= "auto" then
    return mode == "url"
  end
  if vim.env.TMUX then
    local ok, result = pcall(function()
      return vim.system({ "tmux", "show-environment", "SSH_CONNECTION" }, { text = true }):wait(1000)
    end)
    -- "-SSH_CONNECTION": removed when a local client attached
    if ok and result.code == 0 then
      return (result.stdout or ""):match("^SSH_CONNECTION=") ~= nil
    end
  end
  return (vim.env.SSH_CONNECTION or vim.env.SSH_TTY) ~= nil
end

--- Content of a file, nil when it cannot be read
---@param path string
---@return string|nil
local function read_file(path)
  local fd = vim.loop.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local stat = vim.loop.fs_fstat(fd)
  local data = stat and stat.type == "file" and vim.loop.fs_read(fd, stat.size, 0) or nil
  vim.loop.fs_close(fd)
  return data
end

--- Send a response and close the connection
---@param client userdata
---@param status string
---@param headers table|nil Extra header lines
---@param body string|nil
---@param head_only boolean|nil HEAD: headers only
local function respond(client, status, headers, body, head_only)
  body = body or status .. "\n"
  local lines = {
    "HTTP/1.1 " .. status,
    "Content-Length: " .. #body,
    "X-Content-Type-Options: nosniff",
    "Cache-Control: no-store",
    "Referrer-Policy: no-referrer",
    "Connection: close",
  }
  vim.list_extend(lines, headers or { "Content-Type: text/plain; charset=utf-8" })
  local function close()
    if not client:is_closing() then
      client:close()
    end
  end
  client:write(table.concat(lines, "\r\n") .. "\r\n\r\n" .. (head_only and "" or body), function(err)
    -- The browser went away: no shutdown to wait for
    if err or not client:shutdown(close) then
      close()
    end
  end)
end

--- Answer a request head: GET or HEAD /<token>/<name> (the name is only for the browser)
---@param client userdata
---@param head string
local function answer(client, head)
  local method, target = head:match("^(%u+) (%S+) HTTP/1%.%d\r\n")
  if not method then
    return respond(client, "400 Bad Request")
  end
  if method ~= "GET" and method ~= "HEAD" then
    return respond(client, "405 Method Not Allowed", { "Content-Type: text/plain; charset=utf-8", "Allow: GET, HEAD" })
  end
  local token = target:match("^/(%x+)/") or target:match("^/(%x+)$")
  local path = token and files[token]
  local data = path and read_file(path)
  if not data then
    return respond(client, "404 Not Found")
  end
  local content_type = TYPES[(path:match("%.(%w+)$") or ""):lower()]
  local headers = { "Content-Type: " .. (content_type or "application/octet-stream") }
  if not content_type then
    table.insert(headers, "Content-Disposition: attachment")
  elseif content_type:match("^text/html") then
    table.insert(headers, "Content-Security-Policy: " .. (policies[token] or csp))
  end
  respond(client, "200 OK", headers, data, method == "HEAD")
end

--- Read the request head of a new connection, then answer it
---@param client userdata
local function accept(client)
  local head = ""
  client:read_start(function(err, chunk)
    if err or not chunk then
      if not client:is_closing() then
        client:close()
      end
      return
    end
    head = head .. chunk
    if #head > MAX_HEAD then
      client:read_stop()
      respond(client, "431 Request Header Fields Too Large")
    elseif head:find("\r\n\r\n", 1, true) then
      client:read_stop()
      answer(client, head)
    end
  end)
end

--- Start listening, once
---@return string|nil error
local function start()
  if server then
    return nil
  end
  csp = require("xray.util").BROWSER_CSP
  local wanted = options().port
  local address = options().bind or "127.0.0.1"
  local tcp = vim.loop.new_tcp()
  -- libuv reports a port taken at bind or at listen
  local ok, err, name = tcp:bind(address, wanted)
  if ok then
    ok, err, name = tcp:listen(16, function(listen_err)
      if listen_err then
        return
      end
      local client = vim.loop.new_tcp()
      if tcp:accept(client) then
        accept(client)
      else
        client:close()
      end
    end)
  end
  if not ok then
    tcp:close()
    if name == "EADDRINUSE" then
      return ("port %d is taken (another Neovim serving files?): set serve.port, and forward that port"):format(wanted)
    end
    return ("cannot listen on %s:%d: %s"):format(address, wanted, err)
  end
  server, port = tcp, wanted
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("xray_serve", { clear = true }),
    callback = function()
      server:close()
    end,
  })
  return nil
end

--- URL serving a file, starting the server if needed
---@param path string
---@param opts table|nil { csp: policy of this HTML page instead of util.BROWSER_CSP }
---@return string|nil url, string|nil error
function M.url(path, opts)
  path = vim.loop.fs_realpath(path)
  if not path then
    return nil, "no such file"
  end
  local err = start()
  if err then
    return nil, err
  end
  local token = tokens[path]
  if not token then
    token = vim.loop.random(16):gsub(".", function(c)
      return ("%02x"):format(c:byte())
    end)
    files[token], tokens[path] = path, token
  end
  policies[token] = opts and opts.csp or nil
  local name = vim.fs.basename(path):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end)
  local host = options().host or "localhost"
  return ("http://%s:%d/%s/%s"):format(host, port, token, name), nil
end

--- Hand something to open over to the device on the other end of SSH: a link (https:,
--- mailto:) as it is, a file as the URL serving it. Shown, and copied to the clipboard
---@param target string
---@param opts table|nil { csp: see M.url, message: shown before the URL (default "Open on your device") }
---@return string|nil error, string|nil url
function M.open(target, opts)
  local url, err = target, nil
  if not target:match("^%a[%w+.-]*:") then
    url, err = M.url(target, opts)
    if not url then
      return err, nil
    end
  end
  local message = opts and opts.message or "Open on your device"
  local function show(copied)
    vim.notify(("[xray] %s%s: %s"):format(message, copied and (" (" .. copied .. ")") or "", url), vim.log.levels.INFO)
  end
  --- Copy to the + register (OSC 52 over SSH)
  local function register()
    return vim.fn.has("clipboard") == 1 and pcall(vim.fn.setreg, "+", url) and "copied" or nil
  end
  if not options().clipboard then
    show(nil)
    return nil, url
  end
  local client = require("xray.client")
  if client.termux_in_front() then
    -- Straight to the phone's clipboard: OSC 52 reaches Termux only if tmux forwards it
    client.termux_copy(url, function(copy_err)
      show(copy_err and register() or "copied to the phone")
    end)
    return nil, url
  end
  show(register())
  return nil, url
end

return M
