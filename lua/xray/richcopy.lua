-- Copy a Markdown buffer (copy_buffer(), :Xray copy) as rich text, to paste in apps
-- that read the clipboard's text/html flavor, such as Teams: pandoc converts it to HTML,
-- and its local images are inlined as data: URIs (the app cannot read the files). The HTML
-- then goes to the clipboard of the device you type on. OSC 52, which takes "+y over SSH,
-- carries plain text only, so:
--   - locally, wl-copy or xclip puts it there;
--   - over SSH from a PC, a Unix socket the PC's ssh forwards (richcopy.socket) hands it
--     to bin/xray-richcopy-listen, which runs wl-copy or xclip over there;
--   - from the phone (Termux, whose clipboard API is plain text only), or when that socket
--     does not answer, a copy page is served (serve.lua): its Copy button puts the HTML on
--     the browser's clipboard.
local M = {}

local util = require("xray.util")

-- Image formats that are inlined: file extension (util.sniff) -> MIME type
local CONTENT_TYPES = {
  png = "image/png",
  jpg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  bmp = "image/bmp",
}

--- Command that puts text/html on the clipboard, for the session's display server
---@return table|nil
local function clipboard_command()
  if vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-copy") == 1 then
    return { "wl-copy", "--type", "text/html" }
  end
  if vim.env.DISPLAY and vim.fn.executable("xclip") == 1 then
    return { "xclip", "-selection", "clipboard", "-t", "text/html" }
  end
  return nil
end

--- Inline the local images of an HTML fragment as data: URIs
---@param html string
---@param dir string Folder relative image paths are resolved from
---@return string html, table errors One message per image that cannot be inlined
function M.inline_images(html, dir)
  local errors, cache = {}, {}

  --- data: URI of the image a src points to
  ---@param src string Decoded src attribute
  ---@return string|nil
  local function inline(src)
    local relative = not src:match("^[/~]") and not src:match("^file:")
    local path, content, err = util.read_target(relative and (dir .. "/" .. src) or src)
    if not content then
      table.insert(errors, ("%s: %s"):format(src, err))
      return nil
    end
    local content_type = CONTENT_TYPES[util.sniff(content) or ""]
    if not content_type then
      table.insert(errors, ("%s: not an image Teams can show"):format(vim.fn.fnamemodify(path, ":t")))
      return nil
    end
    return ("data:%s;base64,%s"):format(content_type, vim.base64.encode(content))
  end

  local result = html:gsub('(<img%s[^>]-src=")([^"]*)(")', function(before, src, after)
    src = util.decode(src)
    if not util.local_path(src) then
      return nil
    end
    if cache[src] == nil then
      cache[src] = inline(src) or false
    end
    return cache[src] and (before .. cache[src] .. after) or nil
  end)
  return result, errors
end

--- Socket forwarded to the PC's listener
---@return string
local function socket_path()
  return require("xray").config().richcopy.socket
    or ("/tmp/xray-richcopy-%s.sock"):format(vim.uv.os_get_passwd().username)
end

--- Page that puts the HTML on the browser's clipboard with its Copy button
---@param html string
---@param nonce string Of its one script, allowed by its policy
---@return string
local function copy_page(html, nonce)
  return ([[<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Copy as rich text</title>
<style>
body { font-family: sans-serif; margin: 0 16px 32px; }
#bar { position: sticky; top: 0; background: Canvas; padding: 12px 0; display: flex; gap: 12px; align-items: center; }
#copy { font-size: 1.2em; padding: 12px 24px; }
#content { border-top: 1px solid GrayText; padding-top: 8px; }
img { max-width: 100%%; }
</style></head>
<body>
<div id="bar"><button id="copy" type="button">Copy</button><span id="status">then paste it in Teams</span></div>
<div id="content">%s</div>
<script nonce="%s">
const content = document.getElementById("content");
const statusLine = document.getElementById("status");
// A selection copied by the browser carries text/html as well
function copySelection() {
  const range = document.createRange();
  range.selectNodeContents(content);
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  const ok = document.execCommand("copy");
  selection.removeAllRanges();
  if (!ok) throw new Error("the browser refused to copy");
}
document.getElementById("copy").addEventListener("click", async () => {
  const html = '<meta charset="utf-8">' + content.innerHTML;
  try {
    try {
      await navigator.clipboard.write([new ClipboardItem({
        "text/html": new Blob([html], { type: "text/html" }),
        "text/plain": new Blob([content.innerText], { type: "text/plain" }),
      })]);
    } catch (e) {
      copySelection();
    }
    statusLine.textContent = "Copied: paste it in Teams";
  } catch (e) {
    statusLine.textContent = "Could not copy: " + e.message + ". Select the text below and copy it.";
  }
});
</script>
</body></html>
]]):format(html, nonce)
end

--- Serve the copy page and show its URL (copied to the + register, which reaches the device)
---@param html string
---@param reason string|nil Why the PC's listener was not used
local function open_copy_page(html, reason)
  local nonce = vim.uv.random(16):gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end)
  local path = vim.fn.tempname() .. ".html"
  if vim.fn.writefile(vim.split(copy_page(html, nonce), "\n", { plain = true }), path) ~= 0 then
    vim.notify("[xray] Cannot write the copy page " .. path, vim.log.levels.ERROR)
    return
  end
  local csp = util.BROWSER_CSP:gsub("script%-src 'none'", ("script-src 'nonce-%s'"):format(nonce))
  local message = "Open on your device and tap Copy"
  if reason then
    message = ("Could not reach your PC's clipboard: %s %s"):format(reason, message)
  end
  local err = require("xray.serve").open(path, { csp = csp, message = message })
  if err then
    vim.notify("[xray] Cannot serve the copy page: " .. err, vim.log.levels.ERROR)
  end
end

--- Put the HTML on the clipboard of the machine running Neovim
---@param html string
---@return boolean ok
local function copy_locally(html)
  local command = clipboard_command()
  if not command then
    vim.notify(
      "[xray] Copying rich text needs wl-copy (Wayland) or xclip (X11) on the machine running Neovim",
      vim.log.levels.ERROR
    )
    return false
  end
  local job = vim.fn.jobstart(command, { stdin = "pipe" })
  if job <= 0 then
    vim.notify("[xray] Cannot run " .. command[1], vim.log.levels.ERROR)
    return false
  end
  vim.fn.chansend(job, html)
  vim.fn.chanclose(job, "stdin")
  return true
end

--- Copy Markdown as rich text
---@param markdown string
---@param dir string Folder relative image paths are resolved from
function M.copy(markdown, dir)
  if vim.fn.executable("pandoc") ~= 1 then
    vim.notify("[xray] pandoc not found: it converts the Markdown to rich text", vim.log.levels.ERROR)
    return
  end
  if not vim.base64 then
    vim.notify("[xray] Copying rich text needs Neovim 0.10+", vim.log.levels.ERROR)
    return
  end
  local command = { "pandoc", "--from=gfm+hard_line_breaks", "--to=html5", "--wrap=none", "--no-highlight" }
  vim.system(command, { stdin = markdown, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify("[xray] pandoc failed: " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
        return
      end
      local html, errors = M.inline_images(result.stdout or "", dir)
      local warning = #errors > 0 and ("images left as links:\n" .. table.concat(errors, "\n")) or nil

      --- Tell what was copied
      ---@param where string
      local function copied(where)
        local message = "[xray] Copied as rich text" .. (where and (" " .. where) or "")
        if warning then
          vim.notify(message .. "; " .. warning, vim.log.levels.WARN)
        else
          vim.notify(message .. ": paste it in Teams", vim.log.levels.INFO)
        end
      end

      --- Serve the copy page, telling first of the images it shows as links
      ---@param reason string|nil
      local function copy_page_instead(reason)
        if warning then
          vim.notify("[xray] Rich text with " .. warning, vim.log.levels.WARN)
        end
        open_copy_page(html, reason)
      end

      if not require("xray.serve").remote() then
        -- A clipboard pasted as HTML is read as a fragment: the charset hint keeps accents
        if copy_locally('<meta charset="utf-8">' .. html) then
          copied()
        end
        return
      end
      local client = require("xray.client")
      if client.termux_in_front() then
        return copy_page_instead()
      end
      client.send(socket_path(), '<meta charset="utf-8">' .. html, function(err)
        if err then
          -- No socket: no forward set up, nothing to report
          copy_page_instead(not err:match("^no ") and (err .. ", is xray-richcopy-listen running on your PC?") or nil)
        else
          copied("to your PC's clipboard")
        end
      end)
    end)
  end)
end

--- Copy the current buffer, or the lines of a visual selection, as rich text
---@param first number|nil First line (1-based)
---@param last number|nil Last line
function M.copy_buffer(first, last)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, (first or 1) - 1, last or -1, false)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
  M.copy(table.concat(lines, "\n"), dir)
end

return M
