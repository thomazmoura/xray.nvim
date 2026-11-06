-- Small helpers the modules share: reading the files a link points to, telling an image
-- format from its content, and the policy of the HTML pages handed to a browser
local M = {}

-- Policy of the HTML pages opened in a browser (sent as a header too when served, see
-- serve.lua): no scripts, plugins, frames, forms or base URL. A page's own <meta> policy
-- can only restrict it further
M.BROWSER_CSP = "script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"

-- Leading bytes of the image formats told from their content: extension -> magic
local SIGNATURES = {
  { ext = "png", magic = "\137PNG\r\n\26\n" },
  { ext = "jpg", magic = "\255\216\255" },
  { ext = "gif", magic = "GIF87a" },
  { ext = "gif", magic = "GIF89a" },
  { ext = "bmp", magic = "BM" },
  { ext = "tiff", magic = "II*\0" },
  { ext = "tiff", magic = "MM\0*" },
}

--- Image format of some content, from its leading bytes
---@param bytes string
---@return string|nil ext "png", "jpg", "gif", "bmp", "tiff" or "webp"
function M.sniff(bytes)
  for _, sig in ipairs(SIGNATURES) do
    if bytes:sub(1, #sig.magic) == sig.magic then
      return sig.ext
    end
  end
  if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
    return "webp"
  end
  return nil
end

local ENTITIES = { lt = "<", gt = ">", quot = '"', apos = "'", amp = "&" }

--- Decode HTML/XML entities (named and numeric) of an attribute
---@param s string|nil
---@return string|nil
function M.decode(s)
  if not s then
    return nil
  end
  return (
    s:gsub("&(#?x?)(%w+);", function(kind, value)
      if kind == "#" then
        return vim.fn.nr2char(tonumber(value))
      elseif kind == "#x" then
        return vim.fn.nr2char(tonumber(value, 16))
      end
      return ENTITIES[value]
    end)
  )
end

--- Read a file
---@param path string
---@return string|nil content, string|nil error
function M.read(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local content = file:read("*a")
  file:close()
  return content, nil
end

--- File a local link points to (nil for web, mailto:, cid:, data: and other URLs)
---@param target string Decoded src/href attribute
---@return string|nil
function M.local_path(target)
  local path = target:match("^file://(.*)$")
  if not path then
    if target:match("^%a[%w+.-]*:") then
      return nil
    end
    path = target
  end
  return vim.fn.fnamemodify(vim.fs.normalize(path), ":p")
end

--- Read the file a local link points to, trying it URL-decoded (%20...) when it is not
--- found as written
---@param target string Decoded src/href attribute
---@return string|nil path, string|nil content, string|nil error
function M.read_target(target)
  local path = M.local_path(target)
  local content, err = M.read(path)
  if content then
    return path, content, nil
  end
  local unescaped = M.local_path((target:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)))
  local unescaped_content = M.read(unescaped)
  if unescaped_content then
    return unescaped, unescaped_content, nil
  end
  return nil, nil, err or "cannot be read"
end

return M
