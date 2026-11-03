<div align="center">

# BSD Setup for Mac

**FreeBSD on Apple Silicon Macs, in one command.**

*QEMU + HVF, UEFI boot with the FreeBSD loader, GELI-encrypted ZFS with boot environments, an integrity seal checked before every boot, verified downloads, a first-boot wizard, and the commands you'll actually use: `bsdopen`, `bsdclose`, `bsduninstall`, `bsdseal`.*

![Platform: macOS Apple Silicon](https://img.shields.io/badge/macOS-Apple%20Silicon-black)
![Guest: FreeBSD 15.1 arm64](https://img.shields.io/badge/guest-FreeBSD%2015.1%20arm64-ab2b28)
![Shell: bash](https://img.shields.io/badge/shell-bash-blue)

</div>

---

## 🚀 Install

```bash
bash <(curl -fsSL https://bsd.arifcinartekin.me/install)
```

That's it. `/install` is `bsdopen-setup.sh` from `main`, published by GitHub Pages (the same file is at `raw.githubusercontent.com/arifcinartekin/bsdsetupformac/main/bsdopen-setup.sh`). Every download is pinned by sha256 in the script.

Early on it asks for a **disk passphrase**: the FreeBSD disk is encrypted with GELI and the boot loader asks for this passphrase at every boot. There is no way to recover the data without it. Use plain ASCII characters: the loader cannot read others.

When it finishes, it offers to start FreeBSD right away. Enter the disk passphrase, then log in as **`root`** with password **`root`**. The first-boot wizard takes over from there.

> Takes roughly 10–15 minutes, mostly downloads. You need about 2 GB of free disk space to start; the VM disk grows up to 20 GB as you use it. If `~/Downloads` already has `FreeBSD-15.1-RELEASE-arm64-aarch64-bootonly.iso.xz` (or the `.iso`) with the right checksum, the setup uses it instead of downloading it again.

---

## 🧰 Commands

| Command | Where | What it does |
|---|---|---|
| `bsdopen` | Mac | Checks the VM files against the integrity seal, then boots FreeBSD in the current terminal (serial console, no window). Resizing the terminal window resizes the console inside FreeBSD too. Refuses to boot if a file changed |
| `bsdclose` | Mac | Shuts FreeBSD down cleanly from another terminal: presses the VM's power button, falls back to a hard stop after 90 s. `bsdclose --force` stops it immediately |
| `bsduninstall` | Mac | Removes what the setup installed. Asks about each item separately, so you can keep QEMU or the VM disk and remove the rest |
| `bsdseal verify` / `bsdseal accept` | Mac | Checks the seal by hand / shows what changed and seals the current state after you confirm |
| `ssh -p 2223 <user>@localhost` | Mac | SSH into the running VM (bound to `127.0.0.1` only). Port 2223, so it can run next to [Arch Setup for Mac](https://github.com/arifcinartekin/archsetupformac) on 2222 |

Inside the VM, `sudo poweroff` works too, and so does <kbd>Ctrl</kbd>+<kbd>A</kbd> then <kbd>X</kbd> (instant hard stop). <kbd>Ctrl</kbd>+<kbd>C</kbd> goes to the program running inside FreeBSD, as in any terminal; it does not stop the VM.

---

## 🪄 What happens

```
Mac                                         VM
───────────────────────────────────────────────────────────────────────────
1. Homebrew, qemu (only if missing)
   ask for the disk passphrase
2. bootonly ISO      → sha256 pin + FreeBSD's CHECKSUM.SHA256 ✓
   base.txz, kernel.txz → sha256 pin ✓
3. Boot the FreeBSD installer ──────────▶  installer shell (Tab, Enter on its menu)
   (driven over the serial console          GPT: ESP (FAT32) + freebsd-zfs
    with expect, no clicking; the           GELI AES-XTS 256 on the ZFS partition
    passphrase is typed with echo off)      zpool zroot, boot environment layout
                                            base + kernel (checked again against
                                            the ISO's MANIFEST), loader on the ESP,
                                            loader.conf, rc.conf, fstab, ttys,
                                            hostname "freebsd", time zone of the
                                            Mac, terminfo, pkg: sudo zsh git curl…
4. Seal the VM files (Keychain)
   Boot via the launcher: seal check ────▶  the loader asks for the passphrase,
                                            log in, check kernel / ZFS on GELI /
                                            hostname / sshd / size helper,
                                            arm the first-boot wizard
   seal again after the shutdown
5. Add bsdopen / bsdclose / bsduninstall
   / bsdseal to ~/.zshrc
```

### First boot wizard

On the first `bsdopen`, log in as `root` / `root`. A one-time wizard starts and:

1. asks for your **username** (default `user`) and password, and adds you to `wheel` with **sudo**
2. optionally runs [**zsh_setup**](https://github.com/arifcinartekin/zsh_setup) for you: zsh, Oh My Zsh, Powerlevel10k, autosuggestions, syntax highlighting. The p10k configuration wizard runs at the end
3. optionally installs **htop**, **fastfetch** with an `info` command, and [**lsd**](https://github.com/lsd-rs/lsd) (`ls` with colors and icons). fastfetch also runs at every login, so you see the system info each time you `bsdopen`. With lsd, `ls`, `ll`, `la` and `lt` (tree) use it
4. optionally sets up [**ly**](https://github.com/fairyglade/ly) as the login screen on the console (big clock, user and session picker; <kbd>F1</kbd> shuts down, <kbd>F2</kbd> reboots)
5. **locks the root password**, but only after it has verified that your sudo works, so you can't lock yourself out
6. removes itself and logs you out, onto the ly login screen if you chose it. From then on, log in as your own user and use `sudo -i` for root.

Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to skip it. It runs again at the next root login.

> 💡 Powerlevel10k icons need a Nerd Font **in your Mac terminal**, e.g. *MesloLGS NF* (Ghostty ships a Nerd Font by default).

### New to FreeBSD?

| Linux habit | FreeBSD |
|---|---|
| `pacman -S` / `apt install` | `sudo pkg install <name>`, `pkg search <name>` |
| `pacman -Syu` | `sudo pkg upgrade` (packages), `sudo freebsd-update fetch install` (base system) |
| `systemctl status/restart x` | `service x status/restart`; enable at boot with `sudo sysrc x_enable=YES` |
| `/etc/...` for packages | Packages keep their configuration in `/usr/local/etc` |
| btrfs snapshots | `zfs snapshot`, and whole-system snapshots with boot environments: `bectl create before-upgrade`, `bectl list`, `bectl activate <name>` then reboot |
| `man` pages | The [FreeBSD Handbook](https://docs.freebsd.org/en/books/handbook/) is the place to start |

---

## 🔐 Encryption and the integrity seal

**The disk.** One GPT disk: an ESP with the FreeBSD loader, and a `freebsd-zfs` partition encrypted with GELI (AES-XTS, 256-bit key, 4 KiB sectors). Inside it, the ZFS pool `zroot` with lz4 compression and the standard FreeBSD layout: `zroot/ROOT/default` is `/` (a boot environment), plus `zroot/home`, `zroot/tmp`, `zroot/usr/{ports,src}`, `zroot/var/{audit,crash,log,mail,tmp}`. The loader asks for the passphrase on the serial console and hands the key to the kernel, so you type it once. Without the passphrase, `disk.qcow2` is unreadable, whoever copies it.

**The problem GELI does not solve.** The boot chain cannot be encrypted: the UEFI firmware, its variables and the loader on the ESP are plain. Anyone who can change them can put in a loader that records your passphrase the next time you type it, and GELI then protects nothing.

**The seal.** `bsdopen` checks every file in the install directory before it starts QEMU:

- each file's sha256, size and mode: `disk.qcow2` (the ESP is on it), `vars.fd`, `efi-code.fd` (a private copy of the UEFI firmware), `start-uefi.sh`, `bsdclose.sh`, `bsduninstall.sh`, `bsdseal.sh`. A file that was **added** or **removed** counts as a change too
- the digest of that list is kept in your **macOS login Keychain**, not next to the files. Replacing `disk.qcow2` together with the list next to it is not enough to get through the check
- one changed file and **QEMU is not started**: the passphrase prompt never appears. `bsdopen` names what changed

```
INTEGRITY CHECK FAILED: the VM files are not what they were when it last shut down.
  changed: disk.qcow2

  The VM was NOT started, so nothing has asked for your disk passphrase.
```

When the VM shuts down, the launcher seals the new state: the session itself changed `disk.qcow2`. The UEFI variables (`vars.fd`) don't change: every boot runs on a throwaway copy. Hashing runs at about 2 GB/s, so a few seconds per boot for a well-filled disk.

If the last session did not end normally (Mac crashed, the launcher was killed), its changes were never sealed and the next `bsdopen` refuses to boot, with a note that says so. If that is what happened, run `bsdseal accept`: it shows what changed and seals after you confirm.

**What the seal does not protect against.** For this VM, your Mac is the hardware. Code that runs as your macOS user can also edit the launcher, your `~/.zshrc` or QEMU itself, and it can update the Keychain item with the same `security` tool the launcher uses. The seal catches changes made to the VM files while you weren't running them: by another account or app that can write to the folder, a sync or backup tool that restored or overwrote a file, or a damaged file. Against someone with your Mac's disk in their hands, FileVault is what protects you. Keep it on.

---

## 🗑️ Uninstall

```bash
bsduninstall
```

It asks about each item (`y/N`), shows a summary, and asks once more before removing anything:

| Item | Notes |
|---|---|
| FreeBSD virtual disk | `disk.qcow2`, `vars.fd`, `efi-code.fd`: the whole FreeBSD system, plus its seal in the Keychain |
| Download cache and logs | FreeBSD ISO, `base.txz`, `kernel.txz`, `install.log`, `versions.lock` |
| Shell commands | The `bsdopen` block in `~/.zshrc` (all four commands) and `~/.zshrc.bsdopen-backup` |
| SSH host key | `[localhost]:2223` in `~/.ssh/known_hosts`, if present |
| QEMU | `brew uninstall`; tells you if it was already there before the setup |
| xz | Only offered if the setup installed it (it is only needed when the Mac's Python has no `lzma`) |
| `brew autoremove` | Only offered if you removed one of the above |
| Homebrew | Only offered if the setup installed it |

A running VM is shut down first. Once nothing of the install is left, `~/vm/freebsd` is removed, and so is `~/vm` if nothing else is in it. `bsduninstall --all` removes everything without asking. If the commands are already gone:

```bash
bash <(curl -fsSL https://bsd.arifcinartekin.me/uninstall)
```

Nothing inside the VM needs cleaning up: zsh_setup and everything else ran inside FreeBSD and is deleted with the disk.

---

## ⚙️ Configuration

All optional, set as environment variables in front of the install command:

| Variable | Default | |
|---|---|---|
| `BSDOPEN_DIR` | `~/vm/freebsd` | Install directory (keep the path short: the QMP socket path has a limit of ~100 characters) |
| `BSDOPEN_HOSTNAME` | `freebsd` | Hostname inside the VM |
| `BSDOPEN_CPUS` / `BSDOPEN_MEM` | `4` / `4G` | VM resources |
| `BSDOPEN_DISK_SIZE` / `BSDOPEN_ESP_SIZE` | `20G` / `260M` | Disk size (thin-provisioned qcow2) and the ESP on it |
| `BSDOPEN_SSH_PORT` | `2223` | Host port forwarded to the VM's port 22 |
| `BSDOPEN_GELI_PASSPHRASE` | | Disk passphrase, instead of asking for it (needed for an install without a terminal) |
| `BSDOPEN_YES=1` | | Do not ask for confirmation |
| `BSDOPEN_FORCE=1` | | Overwrite an existing install |
| `BSDOPEN_PIN_BREW=1` | | `brew pin qemu` |

Example:

```bash
BSDOPEN_MEM=8G BSDOPEN_DISK_SIZE=64G bash <(curl -fsSL https://bsd.arifcinartekin.me/install)
```

---

## 🔒 Pinned versions and verification

| | Source | Checks |
|---|---|---|
| FreeBSD `15.1-RELEASE` bootonly ISO (installer) | `download.freebsd.org`, then `ftp-archive.freebsd.org` once 15.1 is end of life | sha256 of the `.iso.xz` and of the `.iso` pinned in the script + FreeBSD's published `CHECKSUM.SHA256` |
| `base.txz`, `kernel.txz` | same | sha256 pinned in the script; inside the installer they are checked again against the `MANIFEST` on the verified ISO |
| Packages (`pkg`) | `pkg.FreeBSD.org` | pkg verifies the repository signature with the keys that ship in base |
| Companion scripts | this repo | fetched from the same repo and ref as the setup script |

FreeBSD keeps release files at fixed, versioned URLs, so unlike Arch Linux ARM's moving "latest" tarball there is nothing to mirror. The archive is plain http; that is fine, the pinned sha256 is what is trusted.

### Updating to a new FreeBSD release (maintainers)

Change `FREEBSD_RELEASE` and the four checksums in `bsdopen-setup.sh`: `FREEBSD_ISO_SHA256` and `FREEBSD_ISO_XZ_SHA256` from the release's `CHECKSUM.SHA256-FreeBSD-<release>-arm64-aarch64`, `BASE_TXZ_SHA256` and `KERNEL_TXZ_SHA256` from `https://download.freebsd.org/releases/arm64/aarch64/<release>/MANIFEST`. Check the release announcement's signed checksums against them.

---

## 📁 Repository layout

```
bsdopen-setup.sh                    Mac: the installer (the one-liner runs this)
guest/bsdopen-firstboot.sh          VM:  first-boot wizard (user, sudo, zsh, tools, login screen, root lock)
guest/bsdopen-winsize.sh            VM:  applies the Mac terminal's size to the serial console
mac/bsdclose.sh                     Mac: `bsdclose`
mac/bsduninstall.sh                 Mac: `bsduninstall`
mac/bsdseal.sh                      Mac: `bsdseal`, the integrity seal `bsdopen` checks
third_party/zsh_setup/zsh_setup.sh  VM:  unmodified copy of arifcinartekin/zsh_setup
site/index.html                     bsd.arifcinartekin.me landing page
.github/workflows/pages.yml         Publishes /install and /uninstall on bsd.arifcinartekin.me
```

Files on your Mac after install (`~/vm/freebsd`): `disk.qcow2`, `vars.fd`, `efi-code.fd`, `start-uefi.sh`, `bsdclose.sh`, `bsduninstall.sh`, `bsdseal.sh`, `downloads/`, `install.log`, `versions.lock` (exact versions and package list), `.bsdopen-manifest` (what was installed on the Mac, used by `bsduninstall`) and `.bsdopen-seal` (the sealed file list, used to name what changed). Outside of it: one `bsdopen-seal` item in the login Keychain.

Inside FreeBSD: `/usr/local/sbin/bsdopen-firstboot`, `/usr/local/sbin/bsdopen-winsize` with `/usr/local/etc/rc.d/bsdopen_winsize`, and `/usr/local/etc/bsdopen.conf`.

---

## 🩺 Troubleshooting

| Problem | Fix |
|---|---|
| Install failed | Read `~/vm/freebsd/install.log` with `less` or `cat -v` (plain `cat` lets your terminal answer the escape sequences recorded in it, which leaves junk at your prompt), then run the setup again. It reuses the downloads and redoes the disk |
| `There is already an install` | `bsduninstall` first, or `BSDOPEN_FORCE=1` |
| `INTEGRITY CHECK FAILED` | Something changed a VM file while FreeBSD was off. If you know why (the last session crashed, you restored a backup), `bsdseal accept`. If you don't, don't boot it |
| `no seal ... in the Keychain` | You moved the install directory or the Keychain item is gone: check the files, then `bsdseal accept` |
| Change the disk passphrase | Inside the VM: `sudo geli setkey /dev/vtbd0p2` |
| Forgot the disk passphrase | The data can't be recovered. `bsduninstall` and install again |
| `The FreeBSD VM is already running` | It's open in another terminal. `bsdclose` |
| SSH: `REMOTE HOST IDENTIFICATION HAS CHANGED` | You reinstalled: `ssh-keygen -R "[localhost]:2223"` |
| Plain console login instead of ly (or back) | `sudo bsdopen-firstboot --login-screen console` (or `ly`) |
| Text stays at the old size after resizing the window | `service bsdopen_winsize status` inside FreeBSD shows whether the size helper runs |
| Undo an upgrade that went wrong | Before upgrading: `sudo bectl create before-upgrade`. To go back: `sudo bectl activate before-upgrade` and reboot |
| Locked out of root | `sudo pw unlock root` as your user |
| Skipped zsh setup | As your user: `sh /usr/local/share/bsdopen/zsh_setup.sh` |
| Plain `ls` instead of lsd | Remove the `bsdopen lsd` block from `~/.zshrc` (sh: `~/.shrc`), or run `\ls` once |
| No fastfetch at login | Remove the `bsdopen info` block from `~/.zprofile` (sh: `~/.profile`). The `info` alias is in `~/.zshrc` (sh: `~/.shrc`) |

---

<div align="center">
Made by <a href="https://github.com/arifcinartekin">arifcinartekin</a> · zsh setup from <a href="https://github.com/arifcinartekin/zsh_setup">zsh_setup</a>
</div>
