-- Opening files on another device when Neovim runs over SSH (a phone in Termux, a
-- tablet…): there is no display on this end, so open.lua hands each file to
-- a small HTTP server (shared by your Neovims, see below) instead of vim.ui.open, and shows its URL, copied to
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

-- The files of every Neovim of this user on this machine are served on the one port the URLs
-- name, by a daemon (daemon.lua) the first Neovim to open a file starts, and that leaves once
-- none is left: each lists its files under root (see server.lua), and the daemon answers
-- from there. When it cannot start (or with serve.daemon off), a Neovim serves them itself.

local uv = vim.uv
local server = require("xray.server")

-- <state>/xray-serve
local root

--- This Neovim's directory there
---@return string
local function registry()
  root = root or vim.fn.stdpath("state") .. "/xray-serve"
  return root .. "/" .. uv.os_getpid()
end

-- Listening TCP handle, when this Neovim serves the files itself
local inproc

-- Retrying the port while something else has it (serve.daemon off)
local retry

--- Where to reach the server from this machine (it may listen on all addresses)
---@return string
local function connect_address()
  local address = M.address()
  return (address == "0.0.0.0" and "127.0.0.1") or (address == "::" and "::1") or address
end

--- GET a path from the port, waiting for the answer
---@param path string
---@param timeout number ms
---@return string|nil body, nil when nothing answers; "" for an answer that is not 200
local function get(path, timeout)
  local tcp = uv.new_tcp()
  local chunks, done = {}, false
  tcp:connect(connect_address(), options().port, function(err)
    if err then
      done = true
      return
    end
    tcp:read_start(function(read_err, chunk)
      if read_err or not chunk then
        done = true
      else
        table.insert(chunks, chunk)
      end
    end)
    tcp:write(("GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n"):format(path))
  end)
  vim.wait(timeout, function()
    return done
  end, 5)
  if not tcp:is_closing() then
    tcp:close()
  end
  local response = table.concat(chunks)
  if response == "" then
    return nil
  end
  return response:match("^HTTP/1%.%d 200 [^\r\n]*\r\n.-\r\n\r\n(.*)$") or ""
end

--- The daemon's info file: id, pid, protocol, fingerprint of its code, its folder
---@return table|nil
local function daemon_info()
  registry()
  local file = io.open(root .. "/daemon", "rb")
  if not file then
    return nil
  end
  local fields = vim.split(file:read("*a"), "\n", { trimempty = true })
  file:close()
  return {
    id = fields[1],
    pid = tonumber(fields[2]),
    protocol = tonumber(fields[3]),
    fingerprint = fields[4],
    dir = fields[5],
  }
end

--- What answers on the port:
---   - "daemon": this user's (with its info), "in-process": a Neovim's;
---   - "other": another user's xray, "foreign": anything else (an xray from before the daemon);
---   - nil: nothing.
---@return string|nil state, table|nil info
local function probe()
  local body = get(server.HEALTH, 1000)
  if not body then
    return nil, nil
  end
  local protocol, id = body:match("^xray%-serve (%d+) (%S+)")
  if not protocol then
    return "foreign", nil
  end
  if id == "in-process" then
    return "in-process", nil
  end
  local info = daemon_info()
  if info and info.id == id then
    return "daemon", info
  end
  return "other", nil
end

--- Whether the daemon runs older code than this Neovim has: an older protocol, or its
--- files changed since (a daemon started from another copy of xray is left alone)
---@param info table
---@return boolean
local function outdated(info)
  return (info.protocol or 0) < server.PROTOCOL
    or (info.dir == server.dir() and info.fingerprint ~= server.fingerprint())
end

--- Wait for what answers on the port to change
---@param until_state fun(state: string|nil): boolean
---@param timeout number ms
---@return string|nil state, table|nil info
local function wait_for(until_state, timeout)
  local deadline = uv.now() + timeout
  local state, info = probe()
  while not until_state(state) and uv.now() < deadline do
    vim.wait(50)
    uv.update_time()
    state, info = probe()
  end
  return state, info
end

--- Stop a daemon (one whose pid is still the daemon's), and wait for the port to be free
---@param info table
local function stop(info)
  local cmdline = io.open(("/proc/%d/cmdline"):format(info.pid or 0), "rb")
  local daemon = cmdline and cmdline:read("*a"):find("xray/daemon.lua", 1, true)
  if cmdline then
    cmdline:close()
  end
  if daemon then
    uv.kill(info.pid, "sigterm")
    wait_for(function(state)
      return state ~= "daemon"
    end, 2000)
  end
end

--- Start the daemon, detached: it outlives this Neovim. Its output goes to <root>/daemon.log
---@return string|nil error
local function spawn()
  registry()
  local null = uv.fs_open("/dev/null", "r", 0)
  local log = uv.fs_open(root .. "/daemon.log", "w", tonumber("600", 8))
  local handle, err = uv.spawn(vim.v.progpath, {
    args = { "--clean", "--headless", "-l", server.dir() .. "/daemon.lua", root, M.address(), tostring(options().port) },
    stdio = { null, log, log },
    detached = true,
  }, function()
    -- Exited (or, once this Neovim has gone, never heard of)
  end)
  for _, fd in ipairs({ null, log }) do
    if fd then
      uv.fs_close(fd)
    end
  end
  if not handle then
    return "cannot start the xray daemon: " .. tostring(err)
  end
  handle:unref()
  return nil
end

--- Stop serving from this Neovim, and take its files off the list (VimLeavePre)
local function leave()
  vim.fn.delete(registry(), "rf")
  if inproc then
    inproc:close()
    inproc = nil
  end
end

local start_inproc

--- While another program has the port (serve.daemon off): take it over once it is freed
local function retry_later()
  if retry then
    return
  end
  retry = uv.new_timer()
  retry:start(5000, 5000, vim.schedule_wrap(function()
    if inproc or start_inproc() == nil and inproc then
      retry:stop()
      retry:close()
      retry = nil
    end
  end))
end

--- Serve the files from this Neovim
---@return string|nil error
function start_inproc()
  if inproc then
    return nil
  end
  local tcp, err, name = server.listen({
    root = vim.fs.dirname(registry()),
    address = M.address(),
    port = options().port,
    id = "in-process",
    csp = require("xray.util").BROWSER_CSP,
  })
  if tcp then
    inproc = tcp
    return nil
  end
  if name == "EADDRINUSE" then
    local state = probe()
    if state == "daemon" or state == "in-process" then
      return nil
    end
    retry_later()
  end
  return ("cannot listen on %s:%d: %s"):format(M.address(), options().port, err)
end

--- Make sure something of this user's serves the files listed: the daemon (started, or
--- restarted when older than this Neovim), or this Neovim
---@return string|nil error
local function ensure()
  if inproc then
    return nil
  end
  if not options().daemon then
    return start_inproc()
  end
  local state, info = probe()
  if state == "daemon" and outdated(info) then
    stop(info)
    state = probe()
  end
  if state == "daemon" or state == "in-process" then
    return nil
  elseif state == "foreign" then
    return ("port %d is taken, by another program or an older xray in another Neovim (restart it); or set serve.port"):format(
      options().port
    )
  elseif state == "other" then
    return ("port %d is served by another user's xray: set serve.port"):format(options().port)
  end
  local err = spawn()
  if not err then
    -- Another user's for a moment: the daemon answers before its info file is written
    state = wait_for(function(s)
      return s == "daemon" or s == "in-process" or s == "foreign"
    end, 3000)
    if state == "daemon" or state == "in-process" then
      return nil
    end
  end
  -- The daemon did not come up (its reasons in <root>/daemon.log): serve from here
  return start_inproc()
end

--- Who serves the files, for :Xray check
---@return string
function M.status()
  local state, info = probe()
  if state == "daemon" then
    return ("the daemon, pid %d%s (log: %s/daemon.log)"):format(
      info.pid or 0,
      outdated(info) and ", older code: restarted with the next file opened" or "",
      root
    )
  elseif state == "in-process" then
    if not inproc then
      return "another Neovim"
    end
    return options().daemon and ("this Neovim (the daemon could not start, see " .. root .. "/daemon.log)")
      or "this Neovim (serve.daemon off)"
  elseif state == "foreign" then
    return "something that is not this xray: another program, or an older xray in another Neovim (restart it)"
  elseif state == "other" then
    return "another user's xray: set serve.port"
  end
  return "nothing yet: the daemon starts with the next file opened"
end

-- Tokens of the files served: path -> token (a file opened again keeps its URL)
local tokens = {}

--- URL serving a file, starting the server if needed
---@param path string
---@param opts table|nil { csp: policy of this HTML page instead of util.BROWSER_CSP }
---@return string|nil url, string|nil error
function M.url(path, opts)
  path = uv.fs_realpath(path)
  if not path then
    return nil, "no such file"
  end
  local dir = registry()
  -- Listed before the server starts: the daemon exits when nothing is
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p", tonumber("700", 8))
    -- Only this user can read the list
    uv.fs_chmod(root, tonumber("700", 8))
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("xray_serve", { clear = true }),
      callback = leave,
    })
  end
  local token = tokens[path]
  if not token or not uv.fs_readlink(dir .. "/" .. token) then
    token = token or uv.random(16):gsub(".", function(c)
      return ("%02x"):format(c:byte())
    end)
    tokens[path] = token
    uv.fs_unlink(dir .. "/" .. token)
    uv.fs_symlink(path, dir .. "/" .. token)
  end
  local csp_file = dir .. "/" .. token .. ".csp"
  if opts and opts.csp then
    local file = io.open(csp_file, "wb")
    if file then
      file:write(opts.csp)
      file:close()
    end
  else
    os.remove(csp_file)
  end
  local err = ensure()
  if err then
    return nil, err
  end
  local name = vim.fs.basename(path):gsub("[^%w%-%._~]", function(c)
    return ("%%%02X"):format(c:byte())
  end)
  return ("http://%s:%d/%s/%s"):format(M.host(), options().port, token, name), nil
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
