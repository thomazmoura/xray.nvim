-- Image previews in the terminal (toggle_current(), in Markdown buffers and those plugins attach): the
-- images a buffer links to are drawn below their links, with the best protocol the terminal
-- has (asked once, see detect):
-- - The Kitty graphics protocol (kitty, Ghostty, WezTerm…; through tmux with
--   allow-passthrough on). Each image is sent to the terminal once, then drawn with the
--   protocol's Unicode placeholders: text that Neovim and tmux redraw like any other, so
--   images scroll with the buffer, follow splits and floats, and come back after switching
--   tmux windows.
-- - Sixel (Termux, foot, WezTerm, Konsole, xterm, tmux 3.4+ built with it): the image is a
--   bitmap painted over blank virtual lines after Neovim draws them, and painted again
--   whenever they move. Neovim leaves those cells alone as long as their text does not
--   change, and overwrites (erases) the image when it does.
-- - Half-blocks (any true-color terminal): each cell is a ▀ whose colors are two pixels,
--   plain text again, at a much lower resolution.
-- Each buffer resolves its own links: local files for Markdown buffers, whatever the
-- plugin that attached it says otherwise (M.attach: e-mail attachments, say). Web images
-- are fetched only from preview.safe_domains, over HTTPS (elsewhere, often tracking pixels).
-- With preview.auto, previews turn on as each Markdown buffer opens (an attached buffer
-- decides itself); toggle_current() in any other buffer switches that for the session.
local M = {}

local util = require("xray.util")

local function options()
  return require("xray").config().preview
end

local ns = vim.api.nvim_create_namespace("xray_preview")

-- Cell standing for a cell of an image: the row and column it shows are the diacritics
-- after it (the first 64 of the protocol's list: images are at most 64 rows tall)
local PLACEHOLDER = "\u{10EEEE}"
local DIACRITICS = vim.tbl_map(vim.fn.nr2char, {
  0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B, 0x034C,
  0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
  0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
  0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
  0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
  0x0616, 0x0617, 0x0657, 0x0658,
})

-- Cell size in pixels when the terminal does not report it. The Kitty protocol fits the
-- image in the cells given, keeping its proportions: a wrong guess only changes its size
local DEFAULT_CELL = { width = 10, height = 20 }

-- Cell size Sixel images are drawn for when the terminal does not report it: Sixel is
-- drawn pixel by pixel, so the guess is small, leaving room in the cells kept for the
-- image rather than painting past them
local SIXEL_CELL = { width = 8, height = 16 }

-- Largest share of the window height an image takes: Neovim cannot scroll through part
-- of the virtual lines below a line
local MAX_HEIGHT = 0.5

-- Delay before redrawing the previews of a buffer being edited (ms)
local DEBOUNCE_MS = 300

-- Delay before painting the Sixel images again once the windows changed (ms)
local PAINT_MS = 30

-- How long the terminal has to answer what it supports (ms)
local DETECT_MS = 1000

-- Largest web image downloaded (bytes), and how long its download may take (s)
local MAX_WEB_BYTES = 10 * 1024 * 1024
local WEB_TIMEOUT_S = 15

-- ImageMagick coder of the formats converted to PNG (the only one the protocol takes),
-- by util.sniff: named, so it never guesses the format of untrusted content
local CODERS = { jpg = "jpeg", gif = "gif", bmp = "bmp", tiff = "tiff", webp = "webp" }

-- Terminals with the Kitty graphics protocol and its Unicode placeholders, as tmux names
-- them (client_termname, client_termtype): inside tmux, the terminal's own answer to the
-- protocol's query does not come back
local KITTY_TERMINALS = { "kitty", "ghostty", "wezterm" }

-- What the notifications call each protocol
local LABELS = { kitty = "Kitty graphics", sixel = "Sixel", blocks = "half-blocks" }

-- Save and restore the cursor around a Sixel image (DECSC, DECRC)
local SAVE_CURSOR, RESTORE_CURSOR = "\0277", "\0278"

-- Buffers with previews on: bufnr -> { source, images = { [key] = image }, timer,
-- placements (Sixel: where its images are), painted (Sixel: win -> { [image] = where }) }
local buffers = {}

-- Ids of the images sent to the terminal, which every Neovim (every tmux pane) shares
local ids = {}

-- Cell size in pixels, once asked, and whether the terminal reported it
local cell, measured

-- Protocol the previews are drawn with ("kitty", "sixel" or "blocks") and its renderer,
-- while previews are on in some buffer
local protocol, renderer

-- Highlights of the half-blocks created: name -> true (a color scheme clears them)
local block_hls = {}

-- Pending paint of the Sixel images, and whether it paints even those that did not move
local paint_timer, paint_force

-- Whether previews turn on as Markdown buffers open: preview.auto until switched with
-- toggle_current() outside them (nil until first read, setup() may come after this module)
local auto

math.randomseed(vim.loop.hrtime() + vim.fn.getpid())

--- Whether the terminal is behind a tmux: this Neovim runs inside it, or in a pane of a
--- tmux on another machine (over ssh) that says so through $TMUX_CLIENT_TERMINAL
---@return boolean
local function behind_tmux()
  local path = vim.env.TMUX_CLIENT_TERMINAL
  return vim.env.TMUX ~= nil or (path ~= nil and path ~= "" and vim.uv.fs_stat(path) ~= nil)
end

--- Send an escape sequence to the terminal, through tmux when behind it
---@param seq string
local function send(seq)
  if behind_tmux() then
    -- Passthrough: wrapped in a DCS, every ESC doubled
    seq = "\27Ptmux;" .. seq:gsub("\27", "\27\27") .. "\27\\"
  end
  vim.api.nvim_ui_send(seq)
end

--- A tmux format expanded for this client ("" when tmux cannot be asked)
---@param format string
---@return string
local function tmux_format(format)
  local ok, result = pcall(function()
    return vim.system({ "tmux", "display-message", "-p", format }, { text = true }):wait(1000)
  end)
  return ok and result.code == 0 and vim.trim(result.stdout or "") or ""
end

--- Whether tmux passes escape sequences through to the terminal (allow-passthrough)
---@return boolean
local function tmux_passthrough()
  local ok, result = pcall(function()
    return vim.system({ "tmux", "show-options", "-pAv", "-t", vim.env.TMUX_PANE or "", "allow-passthrough" }, { text = true }):wait(1000)
  end)
  return not (ok and result.code == 0) or vim.tbl_contains({ "on", "all" }, vim.trim(result.stdout or ""))
end

--- What the tmux in front of the terminal knows of its client (the terminal looking right
--- now), or nil when not behind one. Inside tmux, asked of it. In a pane of a tmux on
--- another machine, where neither tmux nor the terminal can be asked (that tmux answers
--- DA1 itself, Sixel or not, and drops the Kitty query), read from the file
--- $TMUX_CLIENT_TERMINAL names, which that tmux rewrites as clients attach. One line:
--- "<termname> <termtype>|<sixel_support>|<termfeatures>|<allow-passthrough>|<cell width> <cell height>"
---@return table|nil { terminal, sixel, features, passthrough, cell (nil: not reported) }
local function client()
  local line
  if vim.env.TMUX then
    line = tmux_format("#{client_termname} #{client_termtype}|#{sixel_support}|#{client_termfeatures}"
      .. "||#{client_cell_width} #{client_cell_height}")
  else
    local path = vim.env.TMUX_CLIENT_TERMINAL
    local ok, lines = pcall(vim.fn.readfile, path or "", "", 1)
    if not (path and path ~= "" and ok and lines[1]) then
      return nil
    end
    line = lines[1]
  end
  local terminal, sixel, features, passthrough, size = unpack(vim.split(line, "|", { plain = true }))
  local width, height = (size or ""):match("^(%d+) (%d+)$")
  width, height = tonumber(width), tonumber(height)
  if vim.env.TMUX then
    passthrough = tmux_passthrough()
  else
    passthrough = vim.tbl_contains({ "on", "all" }, passthrough)
  end
  return {
    terminal = terminal or "",
    sixel = sixel == "1",
    features = vim.split(features or "", ","),
    passthrough = passthrough,
    cell = width and width > 0 and height > 0 and { width = width, height = height } or nil,
  }
end

--- Cell size in pixels of the terminal the TUI runs in: the window size of its tty, which
--- the Neovim server reaches through the TUI's /proc (Linux), or nil
---@return table|nil { width, height }
local function tty_cell()
  local ok, ffi = pcall(require, "ffi")
  if not ok or jit.os ~= "Linux" then
    return nil
  end
  pcall(ffi.cdef, "struct xray_winsize { unsigned short row, col, xpixel, ypixel; };")
  pcall(ffi.cdef, "int open(const char *path, int flags, ...);")
  pcall(ffi.cdef, "int ioctl(int fd, unsigned long request, ...);")
  pcall(ffi.cdef, "int close(int fd);")
  local O_NOCTTY, TIOCGWINSZ = 0x100, 0x5413
  local fd = ffi.C.open(("/proc/%d/fd/1"):format(vim.uv.os_getppid()), O_NOCTTY)
  if fd < 0 then
    return nil
  end
  local size = ffi.new("struct xray_winsize")
  local got = ffi.C.ioctl(fd, TIOCGWINSZ, size) == 0
  ffi.C.close(fd)
  if got and size.col > 0 and size.row > 0 and size.xpixel > 0 and size.ypixel > 0 then
    return { width = math.floor(size.xpixel / size.col), height = math.floor(size.ypixel / size.row) }
  end
  return nil
end

--- Cell size in pixels: tmux's, the terminal's, or a guess
---@return table { width, height }
local function cell_size()
  if cell then
    return cell
  end
  if behind_tmux() then
    measured = vim.tbl_get(client() or {}, "cell")
  elseif vim.tbl_get(vim.api.nvim_list_uis(), 1, "stdout_tty") then
    local ok, size = pcall(tty_cell)
    measured = ok and size or nil
  end
  cell = measured or DEFAULT_CELL
  return cell
end

--- Background the images are drawn on (their transparent pixels): the Normal one
---@return string
local function background()
  local bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  if bg then
    return ("#%06x"):format(bg)
  end
  return vim.o.background == "light" and "#ffffff" or "#000000"
end

--- Why the previews cannot be shown (nil: they can)
---@return string|nil
local function unsupported()
  if not (vim.api.nvim_ui_send and vim.base64) then
    return "Image previews need Neovim 0.12+"
  end
  return nil
end

--- Why the previews cannot be drawn with a protocol (nil: they can)
---@param name string
---@return string|nil
local function unusable(name)
  if not LABELS[name] then
    return ("Unknown preview.protocol %q: use auto, kitty, sixel or blocks"):format(name)
  end
  if name ~= "sixel" and not vim.o.termguicolors then
    return "Image previews need 'termguicolors' (images are drawn in colors of their own)"
  end
  if name == "kitty" and behind_tmux() and not (client() or { passthrough = true }).passthrough then
    return "Image previews need tmux's allow-passthrough: set -g allow-passthrough on"
  end
  if name ~= "kitty" and vim.fn.executable("magick") == 0 then
    return ("Image previews with %s need ImageMagick (magick)"):format(LABELS[name])
  end
  return nil
end

--- The protocol to draw the previews with (preview.protocol, or the best one the terminal
--- has: Kitty, Sixel, half-blocks), passed to callback(name, hint). hint: how to get a
--- better one, or nil. Behind tmux, from what tmux knows of the terminal (see client);
--- otherwise from the terminal's answers to the Kitty query and to DA1 (its features: 4
--- is Sixel)
---@param callback function
local function detect(callback)
  local wanted = options().protocol
  if wanted ~= "auto" then
    return callback(wanted, nil)
  end

  local tmux = behind_tmux() and client()
  if tmux then
    local kitty = vim.iter(KITTY_TERMINALS):any(function(name)
      return tmux.terminal:lower():find(name, 1, true) ~= nil
    end)
    local hint
    if kitty then
      if tmux.passthrough then
        return callback("kitty", nil)
      end
      hint = "set -g allow-passthrough on in tmux for the Kitty graphics protocol"
    end
    -- tmux draws the Sixel images itself, on the terminals it found Sixel in
    if tmux.sixel and vim.tbl_contains(tmux.features, "sixel") then
      return callback("sixel", hint)
    end
    return callback("blocks", hint)
  end

  local id = math.random(1, 0xFFFFFF)
  local timer = assert(vim.uv.new_timer())
  local autocmd, done
  local function finish(name)
    if done then
      return
    end
    done = true
    timer:stop()
    timer:close()
    pcall(vim.api.nvim_del_autocmd, autocmd)
    callback(name, nil)
  end
  autocmd = vim.api.nvim_create_autocmd("TermResponse", {
    nested = true,
    callback = function(ev)
      local seq = ev.data.sequence or ""
      if seq:find("_Gi=" .. id .. ";OK", 1, true) then
        return finish("kitty")
      end
      -- DA1, answered after the Kitty query: the terminal class first, then its features
      local params = seq:match("^\27%[%?([%d;]*)c")
      if params then
        finish(vim.tbl_contains(vim.list_slice(vim.split(params, ";"), 2), "4") and "sixel" or "blocks")
      end
    end,
  })
  timer:start(DETECT_MS, 0, vim.schedule_wrap(function()
    finish("blocks")
  end))
  send(("\27_Gi=%d,s=1,v=1,a=q,t=d,f=24;AAAA\27\\"):format(id))
  vim.api.nvim_ui_send("\27[c")
end

--- Link targets of a line, in order: Markdown links and images ([text](target),
--- [text](<target>), [text](<target> "title"), ![alt](target "title")) and raw <img src="target">
---@param line string
---@return table List of { target, image } image: whether it is an image (![…] or <img>)
function M.targets(line)
  local found = {}
  for pos, target in line:gmatch("()%]%(<([^>]+)>[^%)]*%)") do
    table.insert(found, { pos = pos, target = target })
  end
  for pos, target in line:gmatch("()%]%(([^%)%s<][^%)%s]*)") do
    table.insert(found, { pos = pos, target = target })
  end
  for pos, src in line:gmatch('()<img%s[^>]-src="([^"]*)"') do
    table.insert(found, { pos = pos, target = util.decode(src), image = true })
  end
  table.sort(found, function(a, b)
    return a.pos < b.pos
  end)
  return vim.tbl_map(function(link)
    -- ![alt](…): the "]" found is the one of the alt, its "[" right after a "!"
    local image = link.image or line:sub(1, link.pos):match("!%b[]$") ~= nil
    return { target = link.target, image = image }
  end, found)
end

--- Whether a host is one of preview.safe_domains, or a subdomain of one
---@param host string
---@return boolean
local function safe_host(host)
  host = host:lower()
  return vim.iter(options().safe_domains):any(function(domain)
    domain = domain:lower():gsub("^%*?%.", "")
    return host == domain or vim.endswith(host, "." .. domain)
  end)
end

--- Web image a link points to, when it is on one of preview.safe_domains: downloaded over
--- HTTPS, never following redirects (they could lead off the safe domains)
---@param target string
---@param image boolean Whether the link is a Markdown image or <img>
---@return table|nil source See M.enable
local function web_source(target, image)
  local host = image and target:match("^[Hh][Tt][Tt][Pp][Ss]://([^/:?#]+)")
  if not (host and safe_host(host)) then
    return nil
  end
  local path = target:match("^[^:]+://[^/?#]*([^?#]*)") or ""
  return {
    key = target,
    name = path:match("([^/]+)/*$") or host,
    load = function(callback)
      vim.system({
        "curl", "--silent", "--show-error", "--fail", "--proto", "=https",
        "--max-filesize", tostring(MAX_WEB_BYTES), "--max-time", tostring(WEB_TIMEOUT_S), "--", target,
      }, {}, function(result)
        if result.code ~= 0 then
          -- "curl: (22) The requested URL returned error: 404"
          local err = vim.trim(result.stderr or "")
          return callback(nil, err ~= "" and err or ("curl failed (exit code %d)"):format(result.code))
        end
        callback(result.stdout, nil)
      end)
    end,
  }
end

--- Size of a PNG, from its header
---@param png string
---@return number|nil width, number|nil height
local function png_size(png)
  local function u32(i)
    local a, b, c, d = png:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  if #png < 24 or png:sub(13, 16) ~= "IHDR" then
    return nil, nil
  end
  return u32(17), u32(21)
end

--- An image as PNG: as it is, or converted by ImageMagick (first frame of an animation)
---@param bytes string
---@param callback function Callback(png, error)
local function to_png(bytes, callback)
  local ext = util.sniff(bytes)
  if ext == "png" then
    return callback(bytes, nil)
  end
  if not CODERS[ext] then
    return callback(nil, "not an image")
  end
  if vim.fn.executable("magick") == 0 then
    return callback(nil, ("showing %s images needs ImageMagick (magick)"):format(ext:upper()))
  end
  vim.system(
    { "magick", CODERS[ext] .. ":-[0]", "png:-" },
    { stdin = bytes },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        return callback(nil, "ImageMagick: " .. vim.trim(result.stderr or ""))
      end
      callback(result.stdout, nil)
    end)
  )
end

--- An id no other image of this Neovim has (the 24-bit color of its placeholders)
---@return number
local function new_id()
  local id
  repeat
    id = math.random(1, 0xFFFFFF)
  until not ids[id]
  ids[id] = true
  return id
end

local render, schedule_paint

-- How each protocol draws an image once loaded as PNG:
-- - ready(image): it was just loaded
-- - lines(bufnr, image, cols, rows): the virtual lines showing it in cols x rows cells
-- - free(image): it is no longer shown
-- - paint(): draws the images after Neovim drew the virtual lines (Sixel only)
-- - colorscheme(): the color scheme changed (before the previews are drawn again)
local renderers = {}

renderers.kitty = {
  --- Send the image to the terminal (in 4096-byte base64 chunks), not shown yet
  ready = function(image)
    image.id = new_id()
    local b64 = vim.base64.encode(image.png)
    for i = 1, #b64, 4096 do
      local more = i + 4096 <= #b64 and 1 or 0
      local keys = i == 1 and ("a=t,f=100,t=d,q=2,i=%d,m=%d"):format(image.id, more) or ("m=%d"):format(more)
      send(("\27_G%s;%s\27\\"):format(keys, b64:sub(i, i + 4095)))
    end
  end,

  lines = function(_, image, cols, rows)
    local hl = "PaperboyImage" .. image.id
    -- Set again on every redraw: a color scheme loaded meanwhile clears it
    vim.api.nvim_set_hl(0, hl, { fg = image.id })
    local size = cols .. "x" .. rows
    if image.placed ~= size then
      -- Virtual placement (U=1) the placeholders show; p=1 replaces the previous size
      send(("\27_Ga=p,U=1,q=2,i=%d,p=1,c=%d,r=%d\27\\"):format(image.id, cols, rows))
      image.placed = size
    end
    local lines = {}
    for row = 1, rows do
      -- Row and column on the first cell only: the next ones follow from their left neighbour
      lines[row] = { { PLACEHOLDER .. DIACRITICS[row] .. DIACRITICS[1] .. PLACEHOLDER:rep(cols - 1), hl } }
    end
    return lines
  end,

  --- Delete the image from the terminal
  free = function(image)
    if image.id then
      send(("\27_Ga=d,d=I,q=2,i=%d\27\\"):format(image.id))
      pcall(vim.api.nvim_set_hl, 0, "PaperboyImage" .. image.id, {})
      ids[image.id] = nil
      image.id, image.placed = nil, nil
    end
  end,
}

--- Highlight of a half-block: foreground the upper pixel, background the lower one
---@param fg number 24-bit color
---@param bg number
---@return string
local function block_hl(fg, bg)
  local name = ("PaperboyBlock%06x%06x"):format(fg, bg)
  if not block_hls[name] then
    vim.api.nvim_set_hl(0, name, { fg = fg, bg = bg })
    block_hls[name] = true
  end
  return name
end

--- Virtual lines of half-blocks showing raw RGB pixels, cols x rows*2
---@param rgb string
---@param cols number
---@param rows number
---@return table
local function block_lines(rgb, cols, rows)
  -- A pixel as a 24-bit color, each channel rounded to steps of 8 (fewer highlights)
  local function pixel(y, x)
    local i = (y * cols + x) * 3 + 1
    local r, g, b = rgb:byte(i, i + 2)
    return (r - r % 8) * 0x10000 + (g - g % 8) * 0x100 + (b - b % 8)
  end
  local lines = {}
  for row = 0, rows - 1 do
    local chunks, last, count = {}, nil, 0
    for col = 0, cols - 1 do
      local hl = block_hl(pixel(2 * row, col), pixel(2 * row + 1, col))
      if hl ~= last and last then
        table.insert(chunks, { ("▀"):rep(count), last })
        count = 0
      end
      last, count = hl, count + 1
    end
    table.insert(chunks, { ("▀"):rep(count), last })
    lines[row + 1] = chunks
  end
  return lines
end

renderers.blocks = {
  ready = function() end,

  --- The image resized by ImageMagick to two pixels per cell (once per size), drawn
  --- again when done; until then, the previous size, or that it is loading
  lines = function(bufnr, image, cols, rows)
    local size = cols .. "x" .. rows
    if not (image.blocks and image.blocks.size == size) and image.converting ~= size then
      image.converting = size
      vim.system(
        { "magick", "png:-", "-background", background(), "-flatten", "-resize", ("%dx%d!"):format(cols, rows * 2), "-depth", "8", "rgb:-" },
        { stdin = image.png },
        vim.schedule_wrap(function(result)
          -- Freed, or another size asked meanwhile
          if image.converting ~= size then
            return
          end
          image.converting = nil
          if result.code == 0 and #result.stdout == cols * rows * 6 then
            image.blocks = { size = size, lines = block_lines(result.stdout, cols, rows) }
          else
            local err = "ImageMagick: " .. vim.trim(result.stderr or "")
            image.blocks = { size = size, lines = { { { "  ✗ " .. image.name .. ": " .. err, "DiagnosticError" } } } }
          end
          render(bufnr)
        end)
      )
    end
    return image.blocks and image.blocks.lines or { { { "  Loading " .. image.name .. "…", "Comment" } } }
  end,

  free = function(image)
    image.blocks, image.converting = nil, nil
  end,

  colorscheme = function()
    block_hls = {}
    for _, b in pairs(buffers) do
      for _, image in pairs(b.images) do
        image.blocks, image.converting = nil, nil
      end
    end
  end,
}

--- Paint a Sixel image (the visible rows of it) with its top left corner at a screen cell,
--- encoded by ImageMagick once per size and crop. Returns false when it is still being
--- encoded: painted once it is (schedule_paint)
---@param image table
---@param row number Screen row (1-based) of the first visible row
---@param col number
---@param skip number Rows of the image above the window, not shown
---@param visible number Rows shown
---@param cols number Size of the image in cells
---@param rows number
---@return boolean
local function sixel_paint(image, row, col, skip, visible, cols, rows)
  local px = measured or SIXEL_CELL
  local width, height = cols * px.width, rows * px.height
  -- Whole sixels (6 pixels tall) only: a partial last one would spill into the row below
  local shown = math.floor(visible * px.height / 6) * 6
  if shown == 0 then
    return true
  end
  local key = ("%dx%d+%d+%d"):format(width, height, skip * px.height, shown)
  -- Kept: the whole image, and the last crop (scrolling makes a new one for each row)
  local slot = (skip == 0 and visible == rows) and "whole" or "crop"
  local cached = image.sixels[slot]
  if cached and cached.key == key then
    vim.api.nvim_ui_send(SAVE_CURSOR .. ("\27[%d;%dH"):format(row, col) .. cached.seq .. RESTORE_CURSOR)
    return true
  end
  -- Being encoded, or ImageMagick failed (not tried again)
  if image.encoding[key] then
    return false
  end
  image.encoding[key] = true
  vim.system(
    {
      "magick", "png:-", "-background", background(), "-flatten", "-resize", width .. "x" .. height,
      "-crop", ("%dx%d+0+%d"):format(width, shown, skip * px.height), "+repage", "sixel:-",
    },
    { stdin = image.png },
    vim.schedule_wrap(function(result)
      -- Freed meanwhile
      if not image.sixels then
        return
      end
      if result.code ~= 0 or result.stdout == "" then
        if not image.failed then
          image.failed = true
          vim.notify("[xray] " .. image.name .. ": ImageMagick: " .. vim.trim(result.stderr or ""), vim.log.levels.WARN)
        end
        return
      end
      image.encoding[key] = nil
      image.sixels[slot] = { key = key, seq = result.stdout }
      schedule_paint(false)
    end)
  )
  return false
end

--- Screen areas of the floating windows of the tab page, but one
---@param except number Window
---@return table List of { top, bottom, left, right } (1-based, borders included)
local function float_areas(except)
  local areas = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= except and vim.api.nvim_win_get_config(win).relative ~= "" then
      local info = vim.fn.getwininfo(win)[1]
      table.insert(areas, {
        top = info.winrow - 1,
        bottom = info.winrow + info.height + info.winbar,
        left = info.wincol - 1,
        right = info.wincol + info.width,
      })
    end
  end
  return areas
end

--- Paint the Sixel images of a buffer shown in a window: those that moved, or all (force)
---@param bufnr number
---@param win number
---@param force boolean
local function paint_window(bufnr, win, force)
  local b = buffers[bufnr]
  local info = vim.fn.getwininfo(win)[1]
  local top = info.winrow + info.winbar
  -- Never the last row of the screen: a Sixel image reaching it scrolls the screen
  local bottom = math.min(top + info.height - 1, vim.o.lines - 1)
  local left = info.wincol + info.textoff
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local floats = float_areas(win)
  local before, painted = b.painted[win] or {}, {}

  for _, place in ipairs(b.placements or {}) do
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, place.mark, {})
    local lnum = mark[1] and mark[1] + 1
    -- Screen row of the first row of the image, even above the window
    local first
    if lnum and lnum >= info.topline and lnum <= info.botline then
      local folded = vim.api.nvim_win_call(win, function()
        return vim.fn.foldclosed(lnum) ~= -1
      end)
      local text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      -- Below the last screen row of the line (wrapped lines take several)
      local pos = vim.fn.screenpos(win, lnum, math.max(1, #text))
      if not folded and pos.row > 0 then
        first = pos.row + 1 + place.offset
      end
    elseif lnum and lnum == info.topline - 1 and view.topfill > 0 then
      -- The line is above the window, the last topfill rows of its virtual lines shown
      first = top - (place.total - view.topfill) + place.offset
    end

    if first then
      local skip = math.max(0, top - first)
      local last = math.min(first + place.rows - 1, bottom)
      local visible = last - (first + skip) + 1
      local right = left + place.cols - 1
      local covered = vim.iter(floats):any(function(area)
        return first + skip <= area.bottom and last >= area.top and left <= area.right and right >= area.left
      end)
      if visible > 0 and not covered then
        local where = table.concat({ first + skip, left, skip, visible, place.cols, place.rows }, ":")
        if not force and before[place.image] == where then
          painted[place.image] = where
        elseif sixel_paint(place.image, first + skip, left, skip, visible, place.cols, place.rows) then
          painted[place.image] = where
        end
      end
    end
  end
  b.painted[win] = painted
end

--- Paint the Sixel images of every buffer, after Neovim drew the screen
---@param force boolean Also those that did not move (something may have drawn over them)
local function paint_all(force)
  vim.cmd.redraw()
  local tab = vim.api.nvim_get_current_tabpage()
  for bufnr, b in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local shown = {}
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_get_tabpage(win) == tab then
          shown[win] = true
          paint_window(bufnr, win, force)
        end
      end
      -- Windows closed or on another tab page: painted again when shown
      for win in pairs(b.painted) do
        if not shown[win] then
          b.painted[win] = nil
        end
      end
    end
  end
end

--- Paint the Sixel images soon (once for many events)
---@param force boolean See paint_all
schedule_paint = function(force)
  if not (renderer and renderer.paint) then
    return
  end
  paint_force = paint_force or force
  paint_timer = paint_timer or assert(vim.uv.new_timer())
  paint_timer:stop()
  paint_timer:start(PAINT_MS, 0, vim.schedule_wrap(function()
    local all = paint_force
    paint_force = false
    if renderer and renderer.paint then
      renderer.paint(all)
    end
  end))
end

renderers.sixel = {
  ready = function(image)
    image.sixels, image.encoding = {}, {}
  end,

  --- Blank cells the image is painted over. Their highlight is no other text's, so Neovim
  --- writes over them (erasing the image) whenever something else is drawn there
  lines = function(_, image, cols, rows)
    vim.api.nvim_set_hl(0, "PaperboySixel", { fg = 0x010203 })
    local lines = {}
    for row = 1, rows do
      lines[row] = { { (" "):rep(cols), "PaperboySixel" } }
    end
    image.cols, image.rows = cols, rows
    return lines
  end,

  free = function(image)
    image.sixels, image.encoding, image.failed = nil, nil, nil
  end,

  paint = paint_all,
}

--- Load an image of a buffer, then hand it to the renderer and redraw the buffer
---@param bufnr number
---@param src table See M.toggle
---@return table image { state = "loading"|"ready"|"error", name, error, png, width, height }
local function load(bufnr, src)
  local b = buffers[bufnr]
  local image = { state = "loading", name = src.name }
  b.images[src.key] = image

  local function done(png, err)
    -- Previews turned off, or the link went away meanwhile
    if buffers[bufnr] ~= b or b.images[src.key] ~= image then
      return
    end
    if png then
      image.width, image.height = png_size(png)
      if not image.width then
        png, err = nil, "not a valid PNG"
      end
    end
    if not png then
      image.state, image.error = "error", err or "cannot be read"
    else
      image.state, image.png = "ready", png
      renderer.ready(image)
    end
    render(bufnr)
  end

  src.load(vim.schedule_wrap(function(bytes, err)
    if not bytes then
      return done(nil, err)
    end
    to_png(bytes, done)
  end))
  return image
end

--- Size of an image in cells: its own size when it fits, else shrunk to the window
---@param image table
---@param width number Columns available
---@param max_rows number
---@return number cols, number rows
local function cells(image, width, max_rows)
  local px = cell_size()
  local cols = math.max(1, math.min(width, math.ceil(image.width / px.width)))
  local rows = math.max(1, math.ceil(cols * px.width * image.height / image.width / px.height))
  if rows > max_rows then
    rows = max_rows
    cols = math.max(1, math.min(cols, math.ceil(rows * px.height * image.width / image.height / px.width)))
  end
  return cols, rows
end

--- Virtual lines showing an image (or that it is loading, or failed)
---@param bufnr number
---@param image table
---@param width number Columns available
---@param max_rows number
---@return table
local function image_lines(bufnr, image, width, max_rows)
  if image.state == "loading" then
    return { { { "  Loading " .. image.name .. "…", "Comment" } } }
  elseif image.state == "error" then
    return { { { "  ✗ " .. image.name .. ": " .. image.error, "DiagnosticError" } } }
  end
  local cols, rows = cells(image, width, max_rows)
  return renderer.lines(bufnr, image, cols, rows)
end

--- Draw the images a buffer links to below their links, loading the new ones and
--- deleting from the terminal the ones no longer linked
---@param bufnr number
render = function(bufnr)
  local b = buffers[bufnr]
  if not (b and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  -- Not shown: drawn when it is again (BufWinEnter)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return
  end
  -- Virtual lines are the same in every window showing the buffer: sized for the smallest
  local width, height = math.huge, math.huge
  for _, win in ipairs(wins) do
    local info = vim.fn.getwininfo(win)[1]
    width, height = math.min(width, info.width - info.textoff), math.min(height, info.height)
  end
  width = math.max(1, width)
  local max_rows = math.max(1, math.min(#DIACRITICS, math.floor(height * MAX_HEIGHT)))

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local linked, placements = {}, {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local virt_lines, placed = {}, {}
    for _, link in ipairs(M.targets(line)) do
      local src = b.source(link.target, link.image) or web_source(link.target, link.image)
      if src and not linked[src.key] then
        linked[src.key] = true
        local image = b.images[src.key] or load(bufnr, src)
        local lines = image_lines(bufnr, image, width, max_rows)
        if image.state == "ready" and image.cols then
          table.insert(placed, { image = image, offset = #virt_lines, rows = image.rows, cols = image.cols })
        end
        vim.list_extend(virt_lines, lines)
      end
    end
    if #virt_lines > 0 then
      -- Where the Sixel images are, found again through the mark as the text is edited
      local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { virt_lines = virt_lines })
      for _, place in ipairs(placed) do
        place.mark, place.total = mark, #virt_lines
        table.insert(placements, place)
      end
    end
  end
  b.placements = placements

  for key, image in pairs(b.images) do
    if not linked[key] then
      renderer.free(image)
      b.images[key] = nil
    end
  end
  schedule_paint(false)
end

--- Redraw the previews of every buffer showing them
local function render_all()
  for bufnr in pairs(buffers) do
    render(bufnr)
  end
end

--- Draw the previews with another protocol (another tmux client attached)
---@param name string
local function switch(name)
  local err = unusable(name)
  if err then
    vim.notify("[xray] " .. err, vim.log.levels.WARN)
    return
  end
  for _, b in pairs(buffers) do
    for _, image in pairs(b.images) do
      renderer.free(image)
    end
  end
  protocol, renderer = name, renderers[name]
  for _, b in pairs(buffers) do
    b.placements, b.painted = nil, {}
    for _, image in pairs(b.images) do
      image.cols, image.rows = nil, nil
      if image.state == "ready" then
        renderer.ready(image)
      end
    end
  end
  vim.notify("[xray] Image previews with " .. LABELS[name], vim.log.levels.INFO)
end

--- Ask again what the terminal has, once it may be another one (another tmux client
--- attached) or another size, and redraw the previews for it
local function redetect()
  cell, measured = nil, nil -- the font size may have changed
  if not renderer then
    return
  end
  if behind_tmux() and options().protocol == "auto" then
    detect(function(name)
      if name ~= protocol then
        switch(name)
      end
    end)
  end
  render_all()
end

-- Watch of $TMUX_CLIENT_TERMINAL's directory while previews are on
local client_watch

--- Redetect whenever the tmux on another machine rewrites $TMUX_CLIENT_TERMINAL: a client
--- attaching there may not resize this Neovim. The directory is watched, as the file is
--- replaced whole rather than written to
local function watch_client()
  local path = vim.env.TMUX_CLIENT_TERMINAL
  if client_watch or vim.env.TMUX or not path or path == "" then
    return
  end
  local dir, name = vim.fs.dirname(path), vim.fs.basename(path)
  vim.fn.mkdir(dir, "p")
  client_watch = vim.uv.new_fs_event()
  if not (client_watch and client_watch:start(dir, {}, function(err, filename)
    if not err and filename == name then
      vim.schedule(redetect)
    end
  end)) then
    client_watch = nil
  end
end

--- Stop watching $TMUX_CLIENT_TERMINAL (previews off everywhere)
local function unwatch_client()
  if client_watch then
    client_watch:stop()
    client_watch:close()
    client_watch = nil
  end
end

--- Autocommands of every buffer: sizes, color schemes, the Sixel images to paint again,
--- and the images left in the terminal when Neovim exits (the tmux pane outlives it)
local function setup_global()
  local group = vim.api.nvim_create_augroup("xray_preview", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    -- Behind tmux, maybe another client: with another terminal
    callback = redetect,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "ColorScheme" }, {
    group = group,
    callback = function(ev)
      if ev.event == "ColorScheme" and renderer and renderer.colorscheme then
        renderer.colorscheme()
      end
      render_all()
    end,
  })
  -- Sixel: the images moved, or something drew over them
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function()
      schedule_paint(false)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinClosed", "CompleteDone", "CmdlineLeave", "FocusGained", "VimResume" }, {
    group = group,
    callback = function()
      schedule_paint(true)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for bufnr in pairs(buffers) do
        M.disable(bufnr)
      end
    end,
  })
end

--- Autocommands of a buffer, once: kept while it exists, idle while previews are off
---@param bufnr number
local function setup_buffer(bufnr)
  if vim.b[bufnr].xray_preview then
    return
  end
  vim.b[bufnr].xray_preview = true
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    callback = function()
      render(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    callback = function()
      local b = buffers[bufnr]
      if not b then
        return
      end
      b.timer = b.timer or vim.loop.new_timer()
      b.timer:stop()
      b.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        render(bufnr)
      end))
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = bufnr,
    callback = function()
      M.disable(bufnr)
    end,
  })
end

--- Whether a buffer shows its image previews
---@param bufnr number
---@return boolean
function M.enabled(bufnr)
  return buffers[bufnr] ~= nil
end

--- Whether a buffer links an image its previews would show: one source resolves, or a
--- web image on preview.safe_domains
---@param bufnr number
---@param source function See M.enable
---@return boolean
function M.has_images(bufnr, source)
  return vim.iter(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)):any(function(line)
    return vim.iter(M.targets(line)):any(function(link)
      return (source(link.target, link.image) or web_source(link.target, link.image)) ~= nil
    end)
  end)
end

--- Redraw the previews of a buffer whose contents were replaced (no-op when they are off)
---@param bufnr number
function M.refresh(bufnr)
  render(bufnr)
end

--- Stop showing the image previews of a buffer, deleting its images from the terminal
---@param bufnr number
function M.disable(bufnr)
  local b = buffers[bufnr]
  if not b then
    return
  end
  buffers[bufnr] = nil
  if b.timer then
    b.timer:stop()
    b.timer:close()
  end
  for _, image in pairs(b.images) do
    renderer.free(image)
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  -- The next previews ask the terminal again
  if vim.tbl_isempty(buffers) then
    protocol, renderer = nil, nil
    unwatch_client()
  end
end

--- Show the images a buffer links to, below their links (no-op when already shown)
---@param bufnr number
---@param source function source(target, image): the image a link target points to, or
---   nil to leave the link alone. image: whether the link is a Markdown image or <img>.
---   Returns { key (identifies the image), name, load = function(callback(bytes, error)) }
---@param opts table|nil { quiet }: no notifications, not even why previews cannot be
---   shown (turned on automatically: toggle_current() tells)
function M.enable(bufnr, source, opts)
  local quiet = opts and opts.quiet
  local function notify(msg, level)
    if not quiet then
      vim.notify("[xray] " .. msg, level)
    end
  end
  if buffers[bufnr] then
    return
  end
  local err = unsupported()
  if err then
    notify(err, vim.log.levels.WARN)
    return
  end

  local function enable(name, hint)
    -- Turned on twice while the terminal was being asked, or the buffer went away
    if buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local unusable_err = unusable(name)
    if unusable_err then
      notify(unusable_err, vim.log.levels.WARN)
      return
    end
    if vim.tbl_isempty(buffers) then
      setup_global()
      watch_client()
    end
    protocol, renderer = name, renderers[name]
    buffers[bufnr] = { source = source, images = {}, painted = {} }
    setup_buffer(bufnr)
    render(bufnr)
    notify("Image previews on (" .. LABELS[name] .. ")" .. (hint and ": " .. hint or ""), vim.log.levels.INFO)
  end

  -- Previews already on in another buffer: drawn the same way
  if protocol then
    enable(protocol, nil)
  else
    detect(enable)
  end
end

--- Show or hide the images a buffer links to, below their links
---@param bufnr number
---@param source function See M.enable
function M.toggle(bufnr, source)
  if buffers[bufnr] then
    M.disable(bufnr)
    vim.notify("[xray] Image previews off", vim.log.levels.INFO)
    return
  end
  M.enable(bufnr, source)
end

--- Local image a link of a Markdown file points to: relative paths are the file's own
--- (the way a Markdown viewer resolves them), web images are left out
---@param bufnr number
---@return function source See M.toggle
local function file_source(bufnr)
  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
  return function(target, image)
    if not (image and util.local_path(target)) then
      return nil
    end
    local relative = not target:match("^[/~]") and not target:match("^file:")
    local path = util.local_path(relative and (dir .. "/" .. target) or target)
    local stat = vim.loop.fs_stat(path)
    return {
      key = path .. "@" .. (stat and stat.mtime.sec .. "." .. stat.mtime.nsec or "missing"),
      name = vim.fn.fnamemodify(path, ":t"),
      load = function(callback)
        local content, err = util.read(path)
        callback(content, err)
      end,
    }
  end
end

-- Buffers whose links a plugin resolves its own way: bufnr -> { toggle, auto } (M.attach)
local handlers = {}

--- Let a plugin handle the previews of one of its buffers (an e-mail, say): toggle_current()
--- and auto() call its functions instead of reading the links as local files. Detached
--- when the buffer is wiped out
---@param bufnr number
---@param handler table { toggle = function(bufnr), auto = function(bufnr)|nil (previews
---   on as the buffer opens, when they turn on automatically; nil: never) }
function M.attach(bufnr, handler)
  if not handlers[bufnr] then
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        handlers[bufnr] = nil
      end,
    })
  end
  handlers[bufnr] = handler
end

--- Whether previews turn on as Markdown buffers open (preview.auto, or as switched since)
---@return boolean
function M.auto_enabled()
  if auto == nil then
    return options().auto == true
  end
  return auto
end

--- Turn the previews of a buffer that just opened on, when they turn on automatically:
--- a buffer attached by a plugin decides itself (M.attach), other Markdown buffers only
--- when they are files (not LSP hovers and other scratch buffers)
---@param bufnr number
function M.auto(bufnr)
  if not (M.auto_enabled() and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local handler = handlers[bufnr]
  if handler then
    if handler.auto then
      handler.auto(bufnr)
    end
  elseif vim.bo[bufnr].filetype == "markdown" and vim.bo[bufnr].buftype == "" then
    M.enable(bufnr, file_source(bufnr), { quiet = true })
  end
end

--- Switch the previews of every buffer on or off for the session: on, the Markdown
--- buffers open and those opened next show them; off, every preview is hidden
---@param on boolean
function M.set_auto(on)
  auto = on
  if on then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        M.auto(bufnr)
      end
    end
  else
    for _, bufnr in ipairs(vim.tbl_keys(buffers)) do
      M.disable(bufnr)
    end
  end
  vim.notify("[xray] Image previews " .. (on and "on" or "off") .. " everywhere", vim.log.levels.INFO)
end

--- Show or hide the image previews of the current buffer: a buffer attached by a plugin
--- resolves its links its own way (M.attach), any other Markdown buffer reads local files. Any
--- other buffer has no previews of its own: switch those of every buffer (M.set_auto)
function M.toggle_current()
  local bufnr = vim.api.nvim_get_current_buf()
  local handler = handlers[bufnr]
  if handler then
    handler.toggle(bufnr)
  elseif vim.bo[bufnr].filetype == "markdown" then
    M.toggle(bufnr, file_source(bufnr))
  else
    M.set_auto(not M.auto_enabled())
  end
end

return M
