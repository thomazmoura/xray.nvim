-- The daemon serving the files of every Neovim of this user on this machine (server.lua),
-- started by the first one that finds nothing on the port (serve.lua), detached:
--   nvim --clean --headless -l <this file> <root> <address> <port>
-- It writes <root>/daemon (its id, pid, protocol, code fingerprint and folder), for the
-- Neovims to tell it is theirs and current, and exits once no running Neovim has listed
-- files for IDLE seconds.
local uv = vim.uv

local IDLE = 90

local dir = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(arg[0], ":p")))
-- lua/xray/daemon.lua -> lua/
package.path = vim.fs.dirname(dir) .. "/?.lua;" .. package.path

local server = require("xray.server")
local root, address, port = arg[1], arg[2], tonumber(arg[3])
if not (root and address and port) then
  io.stderr:write("usage: nvim --clean --headless -l daemon.lua <root> <address> <port>\n")
  os.exit(2)
end

local id = uv.random(16):gsub(".", function(c)
  return ("%02x"):format(c:byte())
end)

local tcp, err = server.listen({
  root = root,
  address = address,
  port = port,
  id = id,
  csp = require("xray.util").BROWSER_CSP,
})
if not tcp then
  io.stderr:write(("xray-serve: cannot listen on %s:%d: %s\n"):format(address, port, err))
  os.exit(1)
end

-- Written whole, then renamed: a Neovim never reads half of it
local info = root .. "/daemon"
local file = io.open(info .. ".tmp", "wb")
if file then
  file:write(table.concat({ id, uv.os_getpid(), server.PROTOCOL, server.fingerprint(), dir }, "\n") .. "\n")
  file:close()
  uv.fs_rename(info .. ".tmp", info)
end
io.stderr:write(("xray-serve: pid %d listening on %s:%d\n"):format(uv.os_getpid(), address, port))

local idle, quit = 0, false
local timer = uv.new_timer()
timer:start(10000, 10000, function()
  idle = #server.listings(root) > 0 and 0 or idle + 10
  quit = idle >= IDLE
end)

while not quit do
  vim.wait(60000, function()
    return quit
  end, 200)
end

tcp:close()
-- Unless a newer one took its place
local current = io.open(info, "rb")
if current and current:read("*l") == id then
  os.remove(info)
end
if current then
  current:close()
end
io.stderr:write("xray-serve: idle, exiting\n")
os.exit(0)
