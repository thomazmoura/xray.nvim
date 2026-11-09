-- The HTTP server behind serve.lua's URLs, for every Neovim of this user on this machine:
-- the URLs name one port (forwarded once, or a tunnel's). Each Neovim lists its files in a
-- directory of its own, <root>/<pid>/ (root: <state>/xray-serve), the token linked to the
-- path (and <token>.csp, the policy of a page with its own), and the server answers from
-- there. It runs in the daemon (daemon.lua), or inside a Neovim when that cannot start (see
-- serve.lua). Only libuv here: requests are answered in fast callbacks, where vim.fn is not
-- allowed.
local M = {}

local uv = vim.uv

-- Raised when the requests or the listing change in a way an older server does not follow:
-- a Neovim finding one older restarts it
M.PROTOCOL = 1

-- Path answering who listens: "xray-serve <protocol> <id>" (the daemon's id, which its info
-- file under root has too, or "in-process")
M.HEALTH = "/xray/health"

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

--- Content of a file, nil when it cannot be read
---@param path string
---@return string|nil
local function read_file(path)
  local fd = uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and stat.type == "file" and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  return data
end

--- Remove a Neovim's directory (flat: its links and policies)
---@param dir string
local function remove_listing(dir)
  local scan = uv.fs_scandir(dir)
  while scan do
    local name = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    uv.fs_unlink(dir .. "/" .. name)
  end
  uv.fs_rmdir(dir)
end

--- Directories of the Neovims still running, those of the ones gone without removing theirs
--- removed
---@param root string
---@return string[]
function M.listings(root)
  local dirs = {}
  local scan = uv.fs_scandir(root)
  while scan do
    local pid, kind = uv.fs_scandir_next(scan)
    if not pid then
      break
    end
    if kind == "directory" and pid:match("^%d+$") then
      local dir = root .. "/" .. pid
      if uv.kill(tonumber(pid), 0) then
        table.insert(dirs, dir)
      else
        remove_listing(dir)
      end
    end
  end
  return dirs
end

--- Path and policy of a file listed
---@param root string
---@param token string
---@return string|nil path, string|nil policy
local function lookup(root, token)
  for _, dir in ipairs(M.listings(root)) do
    local path = uv.fs_readlink(dir .. "/" .. token)
    if path then
      return path, read_file(dir .. "/" .. token .. ".csp")
    end
  end
  return nil, nil
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

--- Listen on address:port, answering GET or HEAD /<token>/<name> (the name is only for the
--- browser) with the files listed under root, and M.HEALTH
---@param opts { root: string, address: string, port: number, id: string, csp: string }
--- id: what M.HEALTH tells; csp: policy of the HTML pages without one of their own
---@return userdata|nil tcp, string|nil error, string|nil error_name ("EADDRINUSE": taken)
function M.listen(opts)
  local health = ("xray-serve %d %s\n"):format(M.PROTOCOL, opts.id)

  local function answer(client, head)
    local method, target = head:match("^(%u+) (%S+) HTTP/1%.%d\r\n")
    if not method then
      return respond(client, "400 Bad Request")
    end
    if method ~= "GET" and method ~= "HEAD" then
      return respond(client, "405 Method Not Allowed", { "Content-Type: text/plain; charset=utf-8", "Allow: GET, HEAD" })
    end
    if target == M.HEALTH then
      return respond(client, "200 OK", nil, health, method == "HEAD")
    end
    local token = target:match("^/(%x+)/") or target:match("^/(%x+)$")
    local path, policy
    if token and #token == 32 then
      path, policy = lookup(opts.root, token)
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
      table.insert(headers, "Content-Security-Policy: " .. (policy or opts.csp))
    end
    respond(client, "200 OK", headers, data, method == "HEAD")
  end

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

  local tcp = uv.new_tcp()
  -- libuv reports a port taken at bind or at listen
  local ok, err, name = tcp:bind(opts.address, opts.port)
  if ok then
    ok, err, name = tcp:listen(16, function(listen_err)
      if listen_err then
        return
      end
      local client = uv.new_tcp()
      if tcp:accept(client) then
        accept(client)
      else
        client:close()
      end
    end)
  end
  if not ok then
    tcp:close()
    return nil, err, name
  end
  return tcp, nil, nil
end

--- Folder of xray's modules (lua/xray)
---@return string
function M.dir()
  return vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
end

--- Fingerprint of the server's code on disk: a daemon started from older files is restarted
---@return string
function M.fingerprint()
  local parts = {}
  for _, name in ipairs({ "server.lua", "daemon.lua", "util.lua" }) do
    table.insert(parts, read_file(M.dir() .. "/" .. name) or "")
  end
  return vim.fn.sha256(table.concat(parts, "\0"))
end

return M
