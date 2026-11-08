-- The device you type on, when Neovim runs over SSH: whether it is the phone (Termux), and
-- Unix sockets its ssh forwards back here (RemoteForward), each answered by a listener
-- over there that reads a request until EOF and says "ok" once it worked:
--   - richcopy.socket: the PC's clipboard, as text/html (bin/xray-richcopy-listen);
--   - serve.termux_socket: the phone's clipboard (termux-clipboard-set behind socat);
--   - serve.open_socket: the PC's browser (bin/xray-open-listen, which hands the URL on to
--     the phone when Termux is in front of the PC's own tmux);
--   - serve.termux_open_socket: the phone's browser (termux-open-url behind socat).
local M = {}

-- Longest wait for a listener to answer (ms)
local TIMEOUT = 3000

-- What to do about a stale socket (see M.stale)
M.STALE_HINT = "left over from an ssh connection gone, reconnect (or rerun bin/xray-setup-client on the PC)"

--- Whether the terminal you type on is Termux: in tmux, the client in front (the PC and
--- the phone take turns), which Termux announces with LC_TERMINAL=Termux in its environment
---@return boolean
function M.termux_in_front()
  if not vim.env.TMUX then
    return vim.env.LC_TERMINAL == "Termux"
  end
  local ok, result = pcall(function()
    return vim.system({ "tmux", "display-message", "-p", "#{client_pid}" }, { text = true }):wait(1000)
  end)
  local pid = ok and vim.trim(result.stdout or "") or ""
  if not pid:match("^%d+$") then
    return false
  end
  local file = io.open("/proc/" .. pid .. "/environ", "rb")
  if not file then
    return false
  end
  local environ = file:read("*a")
  file:close()
  return ("\0" .. environ):find("\0LC_TERMINAL=Termux\0", 1, true) ~= nil
end

--- Paths of the forwarded sockets, by what they reach (see the header)
---@return { open: string, termux_open: string, termux_copy: string, richcopy: string }
function M.paths()
  local config = require("xray").config()
  local user = vim.uv.os_get_passwd().username
  return {
    open = config.serve.open_socket or ("/tmp/xray-open-%s.sock"):format(user),
    termux_open = config.serve.termux_open_socket or ("/tmp/xray-open-termux-%s.sock"):format(user),
    termux_copy = config.serve.termux_socket or ("/tmp/termux-clipboard-%s-set.sock"):format(user),
    richcopy = config.richcopy.socket or ("/tmp/xray-richcopy-%s.sock"):format(user),
  }
end

--- Whether an error from send() means the socket is left over from an ssh connection gone:
--- the file is there, nothing listens on it (a later connection forwarded it over the one
--- still open, then closed), or ssh found nothing listening on the device
---@param err string|nil
---@return boolean
function M.stale(err)
  return err ~= nil and (err:match("ECONNREFUSED") ~= nil or err:match("^nothing answered") ~= nil)
end

--- Whether a socket can be connected to, without sending anything (nothing is opened or
--- copied: the listener gets an empty request)
---@param path string
---@param callback fun(state: "missing"|"stale"|"listening", err: string|nil)
function M.probe(path, callback)
  if not vim.uv.fs_stat(path) then
    return callback("missing", nil)
  end
  local pipe = vim.uv.new_pipe(false)
  pipe:connect(path, function(err)
    pipe:close()
    vim.schedule(function()
      callback(err and "stale" or "listening", err)
    end)
  end)
end

--- Send a request to a forwarded socket: the data, then EOF, then wait for "ok"
---@param path string
---@param data string
---@param callback fun(err: string|nil) Called on the main loop. err starts with "no " when
--- the socket does not exist (no forward set up)
function M.send(path, data, callback)
  if not vim.uv.fs_stat(path) then
    return callback("no " .. path)
  end
  local pipe = vim.uv.new_pipe(false)
  local timer = vim.uv.new_timer()
  local done, chunks = false, {}
  local function finish(err)
    if done then
      return
    end
    done = true
    timer:stop()
    timer:close()
    if not pipe:is_closing() then
      pipe:close()
    end
    if not err and not table.concat(chunks):match("^ok\n") then
      -- ssh accepts the connection even when nothing listens over there, then closes it
      err = "nothing answered on " .. path
    end
    vim.schedule(function()
      callback(err)
    end)
  end
  timer:start(TIMEOUT, 0, function()
    finish("no answer on " .. path .. " in time")
  end)
  pipe:connect(path, function(err)
    if err then
      return finish(err .. " on " .. path)
    end
    pipe:read_start(function(read_err, chunk)
      if read_err then
        return finish(read_err)
      elseif chunk then
        table.insert(chunks, chunk)
      else
        finish()
      end
    end)
    pipe:write(data, function(write_err)
      if write_err then
        return finish(write_err)
      end
      pipe:shutdown()
    end)
  end)
end

--- Put text on the phone's clipboard, through serve.termux_socket
---@param text string
---@param callback fun(err: string|nil)
function M.termux_copy(text, callback)
  M.send(M.paths().termux_copy, text, callback)
end

--- Open a URL in the browser of the device you type on: the phone's (serve.termux_open_socket)
--- with Termux in front, else, or when the phone does not answer, the PC's
--- (serve.open_socket). Each ssh connection forwards its own socket: one left behind by a
--- connection gone does not answer, and the next is tried
---@param url string
---@param callback fun(err: string|nil) The PC's error when both failed, unless its socket is
--- missing and the phone's is not
function M.open_url(url, callback)
  local paths = M.paths()
  if not M.termux_in_front() then
    return M.send(paths.open, url .. "\n", callback)
  end
  M.send(paths.termux_open, url .. "\n", function(phone_err)
    if not phone_err then
      return callback(nil)
    end
    M.send(paths.open, url .. "\n", function(pc_err)
      -- The phone's reason is the one that tells, when the PC has no forward at all
      callback(pc_err and pc_err:match("^no ") and phone_err or pc_err)
    end)
  end)
end

return M
