-- :Xray and the previews turning on as Markdown buffers open (preview.auto). No keymaps:
-- map require("xray.preview").toggle_current() and require("xray.richcopy").copy_buffer()
if vim.g.loaded_xray then
  return
end
vim.g.loaded_xray = true

local subcommands = {
  -- :Xray preview [toggle|on|off]: the current buffer's previews; :Xray preview all
  -- switches those of every buffer (preview.auto for the session)
  preview = function(args)
    local preview = require("xray.preview")
    local action = args[1] or "toggle"
    local bufnr = vim.api.nvim_get_current_buf()
    if action == "toggle" then
      preview.toggle_current()
    elseif action == "all" then
      preview.set_auto(not preview.auto_enabled())
    elseif action == "on" then
      if not preview.enabled(bufnr) then
        preview.toggle_current()
      end
    elseif action == "off" then
      preview.disable(bufnr)
    else
      vim.notify("[xray] :Xray preview [toggle|on|off|all]", vim.log.levels.ERROR)
    end
  end,
  -- :[range]Xray copy: the buffer, or the lines of the range, as rich text
  copy = function(_, cmd)
    if cmd.range > 0 then
      require("xray.richcopy").copy_buffer(cmd.line1, cmd.line2)
    else
      require("xray.richcopy").copy_buffer()
    end
  end,
  -- :Xray open [file]: the file (or the one under the cursor) on the device you type on
  open = function(args)
    local target = args[1] and vim.fn.expand(args[1]) or vim.fn.expand("<cfile>")
    local err = require("xray.open").open(target)
    if err then
      vim.notify("[xray] Cannot open " .. target .. ": " .. err, vim.log.levels.ERROR)
    end
  end,
  -- :Xray check: how files and links would open on your device, and which of the sockets
  -- its ssh forwards answer (connected to only: nothing is opened or copied)
  check = function()
    local serve, client = require("xray.serve"), require("xray.client")
    local lines = {
      ("remote: %s (serve.mode %s)"):format(serve.remote(), require("xray").config().serve.mode),
      ("Termux in front: %s"):format(client.termux_in_front()),
      ("URLs: http://%s:%d/…, listening on %s"):format(
        serve.host(),
        require("xray").config().serve.port,
        serve.address()
      ),
      ("served by: %s"):format(serve.status()),
      ("links to localhost open as: %s"):format(serve.rewrite_localhost("http://localhost/")),
    }
    local roles = {
      { "open", "browser (PC)" },
      { "termux_open", "browser (phone)" },
      { "termux_copy", "clipboard (phone)" },
      { "richcopy", "rich copy (PC)" },
    }
    local paths, pending = client.paths(), #roles
    local states = {}
    for i, role in ipairs(roles) do
      client.probe(paths[role[1]], function(state)
        states[i] = ("%s: %s %s"):format(role[2], paths[role[1]], state)
        pending = pending - 1
        if pending == 0 then
          vim.list_extend(lines, states)
          vim.notify("[xray] " .. table.concat(lines, "\n[xray] "), vim.log.levels.INFO)
        end
      end)
    end
  end,
}

vim.api.nvim_create_user_command("Xray", function(cmd)
  local name = table.remove(cmd.fargs, 1)
  local run = subcommands[name or ""]
  if not run then
    vim.notify("[xray] :Xray preview|copy|open|check", vim.log.levels.ERROR)
    return
  end
  run(cmd.fargs, cmd)
end, {
  nargs = "*",
  range = true,
  complete = function(arglead, line)
    local words = vim.split(line, "%s+", { trimempty = true })
    local list = (#words > 2 or (#words == 2 and arglead == "")) and words[2] == "preview"
        and { "toggle", "on", "off", "all" }
      or vim.tbl_keys(subcommands)
    return vim.tbl_filter(function(item)
      return vim.startswith(item, arglead)
    end, list)
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("xray_markdown_preview", { clear = true }),
  pattern = "markdown",
  callback = function(args)
    -- Previews on as the buffer opens (preview.auto), once it is filled and shown
    vim.schedule(function()
      require("xray.preview").auto(args.buf)
    end)
  end,
})

-- Loaded after startup (lazy-loaded): the Markdown buffers already open missed their
-- FileType. Scheduled, as setup() (preview.auto) runs after this file
if vim.v.vim_did_enter == 1 then
  vim.schedule(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "markdown" then
        require("xray.preview").auto(bufnr)
      end
    end
  end)
end
