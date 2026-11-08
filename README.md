# xray.nvim

What a buffer links to, shown and handed to the device you type on, even over SSH:

- **Image previews in the terminal**, below their links: Kitty graphics, Sixel or
  half-blocks, through tmux, and through a tmux on another machine.
- **Rich copy**: a Markdown buffer copied as HTML, to paste in Teams and other apps that
  have no Markdown, onto the clipboard of the PC or phone you ssh from.
- **Opening files over SSH**: files served as URLs and opened in your device's browser, and
  the URL copied there (straight to the phone's clipboard from Termux).

It was split out of [paperboy.nvim](https://github.com/thomazmoura/paperboy.nvim), which
uses it for e-mails.

## Install

```lua
-- lazy.nvim
{
  "thomazmoura/xray.nvim",
  opts = { preview = { auto = true } },
  keys = {
    { "<leader>mv", function() require("xray.preview").toggle_current() end, desc = "Toggle image previews" },
  },
}
```

xray sets no keymaps. Map what you use:

| Function | Command | Does |
|---|---|---|
| `require("xray.preview").toggle_current()` | `:Xray preview` | Previews of this buffer on/off (outside Markdown: of every buffer) |
| `require("xray.richcopy").copy_buffer(first, last)` | `:[range]Xray copy` | The buffer, or lines `first`–`last`, as rich text |
| `require("xray.open").open(path)` | `:Xray open [file]` | A file or link on your device (locally: `vim.ui.open`) |
| | `:Xray check` | How files and links open on your device from here, and which forwarded sockets answer |

Rich copy only makes sense in Markdown buffers, e.g.:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    vim.keymap.set("n", "<leader>mc", function() require("xray.richcopy").copy_buffer() end,
      { buffer = args.buf, desc = "Copy as rich text" })
    vim.keymap.set("x", "<leader>mc", ":Xray copy<cr>", { buffer = args.buf, silent = true, desc = "Copy selection as rich text" })
  end,
})
```

Needs Neovim 0.12+ for the previews (0.10+ for the rest), pandoc for rich copy, and
ImageMagick for most previews (below).

## Image previews in the terminal

`toggle_current()` (`:Xray preview`) shows the images of a Markdown buffer in the terminal,
below their links, and hides them again: its local images, `![alt](<~/path.png>)` and
`<img src="…">`, relative to the file. They are redrawn as you type, and a missing file is
shown in place of the image. Plugins can show the images of their own buffers their own
way (see [For plugins](#for-plugins)): paperboy.nvim does for e-mails and compose buffers.

Web images (`https://…`) are only loaded from the domains you trust: elsewhere, they are
often tracking pixels. List them in `preview.safe_domains`, each one with its
subdomains (`"example.com"` covers `www.example.com`):

```lua
preview = { safe_domains = { "example.com", "githubusercontent.com" } },
```

They are downloaded over HTTPS only (up to 10 MB), and a redirect is not followed: it could
lead off those domains. Only image links are shown, `![alt](https://…)` and `<img src="…">`,
not plain links (`[text](https://…/logo.png)`).

With `preview = { auto = true }`, previews turn on as each Markdown file opens (and the
buffers plugins attach, as they decide). `toggle_current()` in any other buffer (a code
file…) switches this for the session: off hides every preview, and nothing opened next
shows one until you switch it on again. In a Markdown buffer it still toggles that buffer
only. `:Xray preview all` switches it from anywhere.

The images are drawn with the best protocol the terminal has, asked when previews are
turned on (inside tmux, from what tmux knows of the terminal it is attached to; again when
another client attaches). Set `preview.protocol` to always use one:

1. The [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) and
   its Unicode placeholders (kitty, Ghostty, WezTerm…): each image is sent to the terminal
   once, then shown by characters Neovim and tmux redraw like any other text. So images
   scroll with the buffer, fit splits and floats, and come back after you switch tmux
   windows.
2. [Sixel](https://vt100.net/docs/vt3xx-gp/chapter14.html) (Termux, foot, Konsole, xterm
   `-ti vt340`…): the image is painted over blank lines kept for it, after Neovim draws
   them, and painted again whenever they move (scrolling, resizing, a float closed over
   it). It is cut at the edges of the window, and left out while a floating window is over
   it. As the image is a bitmap, not text, something drawn over it can leave a hole:
   toggling twice paints it again.
3. Half-blocks, in any true-color terminal: each cell is a `▀` in the colors of two pixels.
   Plain text, like Kitty's, but too coarse to read a screenshot.

It needs:

- Neovim 0.12+ (`nvim_ui_send`)
- Kitty and half-blocks: `termguicolors` on (each Kitty image is drawn in a color of its
  own, the terminal's id for it)
- [ImageMagick](https://imagemagick.org) (`magick`): Sixel and half-blocks resize every
  image with it, and Kitty takes PNG only, so it converts JPEG, GIF (first frame), BMP,
  TIFF and WebP. The format is found from the content, as when opening an image, and SVG
  is never shown
- Inside tmux, for Kitty: `set -g allow-passthrough on`, and true color (`set -as
  terminal-features ",xterm-ghostty:RGB"`, or the name of your terminal). For Sixel: tmux
  3.4+ built with it (`tmux display -p '#{sixel_support}'` is 1) and a terminal tmux found
  it in (`#{client_termfeatures}` lists `sixel`; else add it: `set -as terminal-features
  ",xterm-256color:sixel"`)

Over ssh in a pane of tmux on another machine, Neovim has no `$TMUX` to ask, and that
tmux answers the terminal queries itself (Sixel, whatever the terminal). Point
`$TMUX_CLIENT_TERMINAL` at a file on this machine that the other tmux keeps up to date
with its client, one line:

```
<client_termname> <client_termtype>|<sixel_support>|<client_termfeatures>|<allow-passthrough>|<client_cell_width> <client_cell_height>
```

for example `xterm-ghostty ghostty 1.3.0|1|RGB,extkeys|on|10 19`. Replace the file whole
(write a copy, then move it over) when another client attaches: the previews switch to
that terminal's protocol as it changes. A tmux hook on `client-attached` and
`client-session-changed` can write it over ssh.

An image is shown at its own size when the window is wide enough, shrunk to fit it
otherwise, and at most half the window tall. Its size in cells comes from the size of the
cells in pixels: the one tmux reports (`client_cell_width`), the one of the terminal
Neovim runs in (Linux), or a guess, small for Sixel, so the image fits in the cells kept
for it. The images are deleted from the terminal when hidden, when their link is gone,
when the buffer is closed and when Neovim exits.

Termux has Sixel since [termux-app#2973](https://github.com/termux/termux-app/pull/2973),
not yet in a release: install a build of its `master` branch (the `Build` workflow's
artifacts on GitHub Actions), as in [docs/termux-sixel.md](docs/termux-sixel.md). Without it, `:Xray open` on an image link opens it on your device
over SSH (see [Opening files over SSH](#opening-files-over-ssh)).

## Rich copy (Teams)

Teams has no Markdown syntax: it pastes the clipboard's `text/html` flavor. In any
Markdown buffer, `copy_buffer()` (or `:Xray copy`, `:'<,'>Xray copy` for a selection) converts the text
with pandoc and copies it as HTML, so pasting in Teams gives bold, italics, lists and
links as formatting, and the local images (`![alt](<~/path.png>)`, relative to the file)
as embedded images: they are inlined as `data:` URIs. Web images stay links. It needs
pandoc, and the HTML goes to the clipboard of the device you type on:

- **Locally**: `wl-copy` (Wayland) or `xclip` (X11) puts it there.
- **Over SSH from a PC**: OSC 52, which takes `"+y` to your PC, carries plain text only. So
  the PC's ssh forwards a Unix socket instead, to `bin/xray-richcopy-listen` running on
  the PC (it needs `socat`, and `wl-copy` or `xclip`). Set it up on the PC, with the hosts
  you ssh into, and once on each of those hosts (see [Setup scripts](#setup-scripts)):

  ```sh
  bin/xray-setup-client my-desktop     # on the PC
  bin/xray-setup-server                # on my-desktop (sudo)
  ```

  Inside tmux, the user service must see the desktop session's `WAYLAND_DISPLAY` (it does
  when started by the graphical session).
- **From the phone (Termux)**, whose clipboard API is plain text only, or when the PC's
  socket does not answer: a copy page is served the way files are (see
  [Opening files over SSH](#opening-files-over-ssh), it needs the same `ssh -L` forward).
  Its URL is shown and copied to the `+` register; open it, tap **Copy**, then paste in
  Teams. Termux is told from the PC by `LC_TERMINAL=Termux` in the environment of the tmux
  client in front.

Set `richcopy.socket` if the forwarded socket is not `/tmp/xray-richcopy-<user>.sock`.

## Opening files over SSH

When Neovim runs on a machine you reach over SSH, from a phone in Termux, for example,
there is no display there for `vim.ui.open`. So `require("xray.open").open(path)`
(`:Xray open`, on the file under the cursor without an argument) serves the file from a
small HTTP server inside Neovim instead. xray shows the URL and copies it to the clipboard, for
you to paste in your device's browser: to the `+` register (over SSH, Neovim copies with
OSC 52, and inside tmux that needs `set -g set-clipboard on`), or, with Termux in front,
straight to the phone's clipboard (below). Web and `mailto:` links are handed over as they
are.

By default the server listens on `127.0.0.1` only, so nothing is open on the network: it is reached
through the SSH connection, with a port forward on your device. In Termux's
`~/.ssh/config`:

```
Host my-desktop
  HostName 192.168.1.10
  ProxyJump my-jump-host        # if you go through one
  LocalForward 8484 localhost:8484
```

or `ssh -L 8484:localhost:8484 my-desktop`. While that session is open, the URLs
(`http://localhost:8484/…/logo.png`) open in the phone's browser. Each file gets a URL of
its own with 128 random bits in it, as the other users of the machine can reach
`127.0.0.1` too. It works until Neovim exits. Files are served with the content type of
their extension (the format found in the content, for images), as `nosniff`. Formats a
browser cannot show are downloaded, and HTML pages get a no-scripts policy
(`util.BROWSER_CSP`).

To reach the server by another name than `localhost`, over a private network such as
Tailscale rather than a port forward, set the host the URLs name, in your own config (or
with `$XRAY_SERVE_HOST`, per machine):

```lua
serve = {
  host = "dev.internal",   -- URLs are http://dev.internal:8484/…
},
```

The server then listens on the address that name resolves to, on the machine it is one of
its own (its Tailscale address, say), and on `127.0.0.1` with `localhost` URLs everywhere
else: the same config can go to every machine. A name this machine resolves to `127.0.0.1`
counts too (`127.0.0.1 dev.internal` in its `/etc/hosts`): for a machine the devices reach
through a tunnel, another machine that answers as `dev.internal` and forwards its ports to
this one's `localhost`. The URLs name `dev.internal`, the server stays on `127.0.0.1`.

Set `serve.bind` (or `$XRAY_SERVE_BIND`) to listen on another address (`"0.0.0.0"`: all of
them), and the URLs name `host` whatever it resolves to. The URLs are then open to every device on that network that can reach the
port: their random part is what keeps the files private.

Links to this machine's `localhost` (`127.0.0.1`, `[::1]`) opened over SSH, a web app you
run here linked from an e-mail, say, name that host too (`http://localhost:5000/` opens as
`http://dev.internal:5000/`): your device has a `localhost` of its own. Set
`serve.localhost` (or `$XRAY_SERVE_LOCALHOST`) for another name than `host`. The app has to
listen on that network too.

With `serve.ui_open = true`, `vim.ui.open` does the same over SSH: `gx` on a link or a
file, and the plugins that open things with it, open on your device, links to `localhost`
renamed. Locally, it is left as it was.

### In the device's browser

The URLs open by themselves in the browser of the device you type on when its ssh forwards
one more Unix socket back, answered over there by something that opens each URL it gets
(`http:`, `https:` and `mailto:` only). Without it, they are only shown and copied.

- **From a PC**: `bin/xray-open-listen` (it needs `socat` and `xdg-open`), set up by the same
  `bin/xray-setup-client` as rich copy, with `bin/xray-setup-server` on the host (see
  [Setup scripts](#setup-scripts)).

- **From the phone (Termux)**: a `socat` listening on a socket in Termux, forwarded the same
  way, that hands the line it reads to `termux-open-url` and answers `ok`:

  ```sh
  socat UNIX-LISTEN:$PREFIX/tmp/xray-open.sock,fork,unlink-early,mode=600 \
    SYSTEM:'read -r url; case $url in http://*|https://*|mailto:*) termux-open-url "$url" && echo ok;; esac'
  ```

  with `RemoteForward /tmp/xray-open-termux-%r.sock /data/data/com.termux/files/usr/tmp/xray-open.sock`:
  a socket of its own, so the PC's connection and the phone's never take each other's.
  Android lets Termux start the browser while it is in front, as it is while you type in it.

With Termux in front (the tmux client in front, or `LC_TERMINAL=Termux` outside tmux), the
phone's socket is tried first, then the PC's. And when you ssh from the phone into the PC's
tmux, and from there on into the host, `bin/xray-open-listen` on the PC hands each URL on to
the phone while Termux is in front of the PC's own tmux, through the phone's socket forwarded
to the PC (`$XRAY_TERMUX_OPEN_SOCKET`, else `/tmp/xray-open-termux-<user>.sock`). Set
`serve.open_socket` and `serve.termux_open_socket` for other paths than
`/tmp/xray-open-<user>.sock` and `/tmp/xray-open-termux-<user>.sock`.

A socket that is there but does not answer was left by an ssh connection gone: another
connection to the host forwarded the same path over the one still open, then closed. xray
says so as it shows the URL. Reconnect, or, for an ssh master (ControlMaster) still running,
run `bin/xray-setup-client` again on the PC: it forwards the sockets of its masters anew.
`:Xray check` shows which sockets answer.

### Setup scripts

- **`bin/xray-setup-client host...`**, on the PC you ssh from (Linux with systemd): runs
  `bin/xray-richcopy-listen` and `bin/xray-open-listen` from this checkout as systemd user
  services (`xray-richcopy`, `xray-open`, started with the graphical session), and adds a
  marked block at the end of `~/.ssh/config` forwarding their sockets to those hosts:

  ```
  Host my-desktop
    RemoteForward /tmp/xray-richcopy-%r.sock /run/user/%i/xray-richcopy.sock
    RemoteForward /tmp/xray-open-%r.sock /run/user/%i/xray-open.sock
  ```

  ssh masters (ControlMaster) already connected to those hosts get the forwards too, for as
  long as they run. Run it again to change the hosts (it rewrites the same block), after
  moving the checkout, when a socket is left over (above), or with `--remove` to take it all
  away.
- **`bin/xray-setup-server`**, once on each host you ssh into (it asks for sudo): sets
  `StreamLocalBindUnlink yes` for sshd, in `/etc/ssh/sshd_config.d/xray-nvim.conf`. sshd
  leaves the socket of a closed connection behind, and without it refuses to forward the
  next one over it.

**Termux**: OSC 52 only reaches the phone's clipboard when every tmux on the way forwards
it. With the clipboard sockets of a Termux setup that forwards
`termux-clipboard-set` (a `RemoteForward` of `/tmp/termux-clipboard-<user>-set.sock` to a
`socat` on the phone that pipes each connection to `termux-clipboard-set` and answers
`ok`), xray copies the URL to the phone directly whenever Termux is the tmux client in
front (`LC_TERMINAL=Termux` in its environment), and says `(copied to the phone)`. When the
socket does not answer, it falls back to the `+` register. Set `serve.termux_socket` for
another path.

With `serve.mode = "auto"` (default), files open as URLs when the client attached right
now came over SSH. Inside tmux, its `SSH_CONNECTION`, which tmux updates on every attach,
tells. So the same Neovim opens the desktop's viewer when you attach from the desktop.
`"url"` always serves, and `"local"` never does. The server starts on the first file
served. Every Neovim of yours on the machine shares that one port: the first to serve a file
listens, and serves the files of the others too, which each list theirs in
`stdpath("state")/xray-serve/`. When it exits, its URLs stop working and another Neovim takes
the port over within seconds. If something else holds the port, the URLs do not answer: set
`serve.port` to another port, and forward that one.

## Configuration

`setup()` can be called more than once: each call merges into the configuration so far.

| Option | Type | Default | Description |
|---|---|---|---|
| `preview.protocol` | string | `"auto"` | `"auto"` (the best the terminal has), `"kitty"`, `"sixel"` or `"blocks"` |
| `preview.auto` | boolean | `false` | Previews on as Markdown files (and attached buffers) open |
| `preview.safe_domains` | table | `{}` | Domains web images are loaded from, each with its subdomains |
| `richcopy.socket` | string | `nil` | Socket forwarded to `bin/xray-richcopy-listen` on your PC (`nil`: `/tmp/xray-richcopy-<user>.sock`) |
| `serve.mode` | string | `"auto"` | Open files as URLs: `"auto"` (when attached over SSH), `"url"` (always) or `"local"` (never) |
| `serve.port` | number | `8484` | Port the URLs are served from (forward it with `ssh -L`) |
| `serve.host` | string | `nil` | Host the URLs name instead of `localhost`, where it names this machine or `bind` is set (fallback: `$XRAY_SERVE_HOST`) |
| `serve.bind` | string | `nil` | Address listened on (`nil`: the one `host` names on this machine, else `127.0.0.1`; fallback: `$XRAY_SERVE_BIND`) |
| `serve.localhost` | string | `nil` | Name that replaces `localhost` in links opened over SSH (`nil`: `host`; fallback: `$XRAY_SERVE_LOCALHOST`) |
| `serve.ui_open` | boolean | `false` | Over SSH, `vim.ui.open` (`gx`…) opens on your device too |
| `serve.open_socket` | string | `nil` | Socket forwarded to `bin/xray-open-listen` on your PC (`nil`: `/tmp/xray-open-<user>.sock`) |
| `serve.termux_open_socket` | string | `nil` | Socket forwarded to `termux-open-url` on the phone, tried first with Termux in front (`nil`: `/tmp/xray-open-termux-<user>.sock`) |
| `serve.clipboard` | boolean | `true` | Copy each URL: to the phone with Termux in front, else to the `+` register |
| `serve.termux_socket` | string | `nil` | Socket forwarded to `termux-clipboard-set` (`nil`: `/tmp/termux-clipboard-<user>-set.sock`) |

## For plugins

A plugin whose buffers resolve their images their own way (e-mail attachments, say) claims
them with `preview.attach`, so `toggle_current()` and `preview.auto` call it:

```lua
local preview = require("xray.preview")
preview.attach(bufnr, {
  toggle = function(bufnr) preview.toggle(bufnr, source) end,
  auto = function(bufnr) preview.enable(bufnr, source, { quiet = true }) end, -- or nil: never
})
```

`source(target, image)` returns the image a link target points to, or nil to leave the
link alone: `{ key = "unique id", name = "logo.png", load = function(callback) callback(bytes, err) end }`.
`preview.enable`, `disable`, `refresh`, `enabled`, `has_images` and `auto_enabled` drive the
previews of a buffer; `require("xray.open").html(html)` opens an HTML page with no scripts,
locally or on the device over SSH.

## License

MIT
