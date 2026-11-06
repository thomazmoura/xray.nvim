# Termux with Sixel images

Image previews (`<leader>mv`) draw full-resolution images in Termux with Sixel. Termux
got Sixel in [termux-app#2973](https://github.com/termux/termux-app/pull/2973), merged
into `master` on 2026-09-11. No release has it yet (the latest, 0.118.3, is from
May 2025), and F-Droid only ships releases. Until one does, install a build of `master`
from GitHub Actions, as below. Without it, the previews fall back to half-blocks, which
are too coarse for screenshots.

## Before you start

- The GitHub builds are signed with a different key than the F-Droid and Play Store
  ones. Android refuses to install one over the other, so **you must uninstall Termux
  first, which deletes its data**: back it up (step 1).
- The `Termux:*` plugins (`Termux:API`, `Termux:Boot`, `Termux:Widget`…) must come from
  the same source as the app, so those you use have to be uninstalled too, and
  installed again from GitHub (their own releases page).
- The artifacts expire 90 days after the build. If the link in step 3 is dead, pick a
  newer successful run of the same workflow.

## 1. Back up Termux

In Termux:

```sh
termux-setup-storage          # allow access to shared storage, once
termux-backup /sdcard/termux-backup.tar.xz
```

Then copy `termux-backup.tar.xz` somewhere outside the phone (your PC, a cloud drive):
if the uninstall also clears shared storage on your device, it is gone too. Your SSH
keys (`~/.ssh`) and `~/.config` are inside it.

## 2. Uninstall

Uninstall Termux, and every `Termux:*` plugin you have, from Android's settings.

## 3. Download the build

On the phone, in a browser signed in to GitHub (artifacts need an account):

1. Open <https://github.com/termux/termux-app/actions/workflows/debug_build.yml>, or
   the repository's **Actions** tab → the **Build** workflow.
2. Open the latest run with a green check on the `master` branch. It must be from
   2026-09-11 or later: that is when Sixel was merged. (The one I checked is commit
   `8629e63`, 2026-09-26.)
3. Scroll to **Artifacts** and download the one that fits your phone:
   `termux-app_v0.118.0+<hash>-apt-android-7-github-debug_arm64-v8a`. Most phones are
   arm64 (`arm64-v8a`) running Android 7 or newer. For Android 5 or 6, take the
   `apt-android-5` one. `universal` works on any phone, but is much bigger.

   The version says 0.118.0, but it does include the Sixel change.
4. The download is a `.zip`. Extract it (the Files app does), and open the `.apk`
   inside. Allow installing apps from this source when Android asks.

From a PC, `gh run download <run-id> -R termux/termux-app -n <artifact-name>` fetches
the same file, and `adb install <file>.apk` installs it over USB, if you would rather.

## 4. Restore

In the new Termux:

```sh
termux-setup-storage
termux-restore /sdcard/termux-backup.tar.xz
```

Copy the backup back to `/sdcard` first if you moved it. Close Termux and open it again.
Check that it works: `pkg update`, then `ssh` into your machine.

## 5. Try it

In Neovim on the remote machine, `<leader>mv` in a Markdown file that links an image
(`![shot](shot.png)`) should say `Image previews on (Sixel)`. If it says
`half-blocks`:

- Inside tmux, tmux has to know the terminal can draw Sixel: tmux 3.4+ built with it
  (`tmux display -p '#{sixel_support}'` prints `1`), and Termux's name listed with the
  feature. Add to `~/.tmux.conf` on the remote machine, then reload it:

  ```tmux
  set -as terminal-features ",xterm-256color:sixel"
  ```

  Replace `xterm-256color` with what `tmux display -p '#{client_termname}'` shows.
- Or force it, to see whether the terminal draws it:
  `require("xray").setup({ preview = { protocol = "sixel" } })`.

## Known problems

- If a Sixel sequence is cut off halfway (the SSH connection drops while an image is
  being sent), Termux can ignore all input until the sequence ends. Close the session
  from Android's notification, and open Termux again.
- A menu or message drawn over an image can leave a hole in it. `<leader>mv` twice paints
  it again.

## Going back to a release

When Termux publishes a release with Sixel, uninstall the GitHub build the same way
(back up, uninstall, install the F-Droid or Play version, restore).
