-- Opening files on another device when Neovim runs over SSH (a phone in Termux, a
-- tablet…): there is no display on this end, so open.lua hands each file to
-- a small HTTP server inside Neovim instead of vim.ui.open, and shows its URL, copied to
-- the clipboard (the phone's through serve.termux_socket with Termux in front, else the +
-- register, which OSC 52 takes to the SSH client's) and opened in the device's browser
-- through serve.open_socket, when its ssh forwards it (see client.lua). By default the
-- server listens on 127.0.0.1 only, reached through the SSH connection itself (ssh -L 8484:localhost:8484):
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

-- Every Neovim of this user on this machine serves the files of all of them: the URLs name
-- one port (forwarded once, or a tunnel's), and the first to open a file takes it. Each one
-- lists its files in a directory of its own, <state>/xray-serve/<pid>/, the token linked to
-- the path (and <token>.csp, the policy of a page with its own), and the one listening looks
-- there for the tokens it does not know. A Neovim leaving takes its directory away (one gone
-- without is skipped, then removed), and another one takes over the port once it is freed.

-- <state>/xray-serve, read on the main loop (vim.fn is not allowed where requests are answered)
local root

--- This Neovim's directory there
---@return string
local function registry()
  root = root or vim.fn.stdpath("state") .. "/xray-serve"
  return root .. "/" .. vim.uv.os_getpid()
end

--- Path and policy of a file another Neovim lists
---@param token string
---@return string|nil path, string|nil policy
local function listed(token)
  if not root then
    return nil, nil
  end
  local scan = vim.uv.fs_scandir(root)
  while scan do
    local pid, kind = vim.uv.fs_scandir_next(scan)
    if not pid then
      break
    end
    if kind == "directory" and pid:match("^%d+$") and tonumber(pid) ~= vim.uv.os_getpid() then
      local dir = root .. "/" .. pid
      if not vim.uv.kill(tonumber(pid), 0) then
        vim.schedule(function()
          vim.fn.delete(dir, "rf")
        end)
      else
        local path = vim.uv.fs_readlink(dir .. "/" .. token)
        if path then
          local file, policy = io.open(dir .. "/" .. token .. ".csp", "rb"), nil
          if file then
            policy = file:read("*a")
            file:close()
          end
          return path, policy
        end
      end
    end
  end
  return nil, nil
end

-- Retrying the port while another Neovim has it
local retry

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

-- Address serve.host resolves to when it is one of this machine's, false when it is not,
-- and the host it was resolved for (cached: resolving can take a while)
local host_address, resolved_host

--- This machine's address serve.host names, nil when it names another machine (the same
--- configuration on every machine: only the one called so listens beyond 127.0.0.1)
---@return string|nil
local function local_host_address()
  local host = options().host
  if not host then
    return nil
  end
  if resolved_host ~= host then
    resolved_host, host_address = host, false
    local mine = {}
    for _, addresses in pairs(vim.uv.interface_addresses() or {}) do
      for _, info in ipairs(addresses) do
        mine[info.ip] = true
      end
    end
    for _, info in ipairs(vim.uv.getaddrinfo(host, nil, { socktype = "stream" }) or {}) do
      if mine[info.addr] then
        host_address = info.addr
        break
      end
    end
  end
  return host_address or nil
end

--- Address the server listens on: serve.bind, else the one serve.host names when it is this
--- machine's, else 127.0.0.1 (reached through ssh -L)
---@return string
function M.address()
  return options().bind or local_host_address() or "127.0.0.1"
end

--- Host the URLs name: serve.host when the server can be reached by it (serve.bind set, or it
--- names this machine), else localhost
---@return string
function M.host()
  local host = options().host
  if host and (options().bind or local_host_address()) then
    return host
  end
  return "localhost"
end

--- A link to this machine's localhost (127.0.0.1, [::1]) with serve.localhost (else the host
--- the URLs name) in its place: the device at the other end of SSH has a localhost of its own
---@param url string
---@return string
function M.rewrite_localhost(url)
  local name = options().localhost or (M.host() ~= "localhost" and M.host()) or nil
  if not name then
    return url
  end
  local scheme, authority, rest = url:match("^(https?://)([^/?#]*)(.*)$")
  if not scheme then
    return url
  end
  local userinfo, hostport = authority:match("^(.*@)(.*)$")
  hostport = hostport or authority
  local host = hostport:match("^%[[^%]]*%]") or hostport:match("^[^:]*")
  local lower = host:lower()
  if lower ~= "localhost" and lower ~= "127.0.0.1" and lower ~= "[::1]" then
    return url
  end
  return scheme .. (userinfo or "") .. name .. hostport:sub(#host + 1) .. rest
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
  local policy = token and policies[token]
  if token and not path and #token == 32 then
    -- Another Neovim's file
    path, policy = listed(token)
  end
  local data = path and read_file(path)
  if not data then
    return respond(client, "404 Not Found")
  end
  local content_type = TYPES[(path:match("%.(%w+)$") or ""):lower()]
  local headers = { "Content-Type: " .. (content_type or "application/octet-stream") }
  if not content_type then
    table.insert(headers, "Content-Disposition: attachment")
  elseif content_type:match("^text/html") then
    table.insert(headers, "Content-Security-Policy: " .. (policy or csp))
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

--- Take this Neovim's files off the list (VimLeavePre)
local function unregister()
  vim.fn.delete(registry(), "rf")
end

local start

--- While another Neovim has the port: take it over once it leaves, so the files listed
--- (this one's and the others') keep being served
local function retry_later()
  if retry then
    return
  end
  retry = vim.uv.new_timer()
  retry:start(5000, 5000, vim.schedule_wrap(function()
    if server or start() == nil and server then
      retry:stop()
      retry:close()
      retry = nil
    end
  end))
end

--- Start listening, once. With the port taken by another Neovim of this user (or anything
--- else: then its URLs do not work), carry on: that one serves the files listed
---@return string|nil error
function start()
  if server then
    return nil
  end
  csp = require("xray.util").BROWSER_CSP
  local wanted = options().port
  local address = M.address()
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
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("xray_serve", { clear = true }),
    callback = function()
      unregister()
      if server then
        server:close()
      end
    end,
  })
  if not ok then
    tcp:close()
    if name == "EADDRINUSE" then
      port = wanted
      retry_later()
      return nil
    end
    return ("cannot listen on %s:%d: %s"):format(address, wanted, err)
  end
  server, port = tcp, wanted
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
    -- For whichever Neovim listens (only this user can read the list)
    vim.fn.mkdir(registry(), "p", tonumber("700", 8))
    vim.uv.fs_chmod(root, tonumber("700", 8))
    vim.uv.fs_symlink(path, registry() .. "/" .. token)
  end
  policies[token] = opts and opts.csp or nil
  local csp_file = registry() .. "/" .. token .. ".csp"
  if policies[token] then
    local file = io.open(csp_file, "wb")
    if file then
      file:write(policies[token])
      file:close()
    end
  else
    os.remove(csp_file)
  end
  local name = vim.fs.basename(path):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end)
  return ("http://%s:%d/%s/%s"):format(M.host(), port, token, name), nil
end

--- Hand something to open over to the device on the other end of SSH: a link (https:,
--- mailto:) as it is, with serve.localhost for localhost, a file as the URL serving it.
--- Opened in the device's browser through serve.open_socket when its ssh forwards it, shown,
--- and copied to the clipboard
---@param target string
---@param opts table|nil { csp: see M.url, message: shown before the URL (default "Open on your device") }
---@return string|nil error, string|nil url
function M.open(target, opts)
  local url, err = target, nil
  if target:match("^%a[%w+.-]*:") then
    url = M.rewrite_localhost(target)
  else
    url, err = M.url(target, opts)
    if not url then
      return err, nil
    end
  end
  local client = require("xray.client")
  local message = opts and opts.message or "Open on your device"
  -- Both answers (opened, copied) are awaited before showing the URL once
  local pending, opened, copied, why = 2, false, nil, nil
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    local text = opened and "Opened on your device" or message
    local notes = vim.tbl_filter(function(note)
      return note ~= nil
    end, { copied, why })
    local suffix = #notes > 0 and (" (" .. table.concat(notes, "; ") .. ")") or ""
    vim.notify(("[xray] %s%s: %s"):format(text, suffix, url), why and vim.log.levels.WARN or vim.log.levels.INFO)
  end
  client.open_url(url, function(open_err)
    opened = open_err == nil
    -- No socket: no forward set up, the URL is only shown and copied as meant
    if open_err and not open_err:match("^no ") then
      why = "not opened, " .. open_err .. (client.stale(open_err) and (": " .. client.STALE_HINT) or "")
    end
    done()
  end)
  --- Copy to the + register (OSC 52 over SSH)
  local function register()
    return vim.fn.has("clipboard") == 1 and pcall(vim.fn.setreg, "+", url) and "copied" or nil
  end
  if not options().clipboard then
    done()
  elseif client.termux_in_front() then
    -- Straight to the phone's clipboard: OSC 52 reaches Termux only if tmux forwards it
    client.termux_copy(url, function(copy_err)
      copied = copy_err and register() or "copied to the phone"
      done()
    end)
  else
    copied = register()
    done()
  end
  return nil, url
end

return M
