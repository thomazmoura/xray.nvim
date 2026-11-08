-- The device you type on, when Neovim runs over SSH: whether it is the phone (Termux), and
-- Unix sockets its ssh forwards back here (RemoteForward), each answered by a listener
-- over there that reads a request until EOF and says "ok" once it worked:
--   - richcopy.socket: the PC's clipboard, as text/html (bin/xray-richcopy-listen);
--   - serve.termux_socket: the phone's clipboard (termux-clipboard-set behind socat);
--   - serve.open_socket: the device's browser (bin/xray-open-listen on a PC,
--     termux-open-url behind socat on the phone).
local M = {}

-- Longest wait for a listener to answer (ms)
local TIMEOUT = 3000

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
      return finish(err)
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
  local path = require("xray").config().serve.termux_socket
    or ("/tmp/termux-clipboard-%s-set.sock"):format(vim.uv.os_get_passwd().username)
  M.send(path, text, callback)
end

--- Open a URL in the browser of the device you type on, through serve.open_socket: the
--- listener over there (PC or phone) knows how
---@param url string
---@param callback fun(err: string|nil)
function M.open_url(url, callback)
  local path = require("xray").config().serve.open_socket
    or ("/tmp/xray-open-%s.sock"):format(vim.uv.os_get_passwd().username)
  M.send(path, url .. "\n", callback)
end

return M
