# vfs0090-rhel

Get the Validity `138a:0090` / `138a:0097` fingerprint sensor working with
`fprintd` on **RHEL 10 / CentOS Stream 10** and derivatives.

If `lsusb` shows something like:

```
Bus 001 Device 017: ID 138a:0090 Validity Sensors, Inc. VFS7500 Touch Fingerprint Sensor
```

(the "VFS7500" name is a stale/wrong string in the USB ID database — the
chip is actually the VFS0090), and `fprintd-list $USER` says `No devices
available` even though `fprintd` is running, this is for you.

## Why this is needed

Short version: RHEL/Fedora's `libfprint` package ships **without** the
`vfs0090` driver. This isn't a bug or a missing config — it's a deliberate
build-time exclusion. The driver is a reverse-engineered implementation of
Validity's proprietary sensor protocol, and it embeds TLS pairing material
that raised legal concerns years ago, so distros compile it out. The udev
rules that ship with `libfprint` still reference the `138a:0090` USB ID
(those rules are shared boilerplate across all drivers), which is what
makes this look like a permissions or udev problem at first — it isn't.

Meanwhile, the actively-maintained out-of-tree driver source
([3v1n0/libfprint-tod-vfs0090](https://github.com/3v1n0/libfprint-tod-vfs0090))
targets a version of libfprint several years newer than what any RHEL10
COPR repo builds against (Fedora-only, no RHEL10 chroot exists as of this
writing), and the driver has a couple of small compatibility bugs against
plain upstream libfprint (it's normally consumed as a
[TOD](https://gitlab.freedesktop.org/libfprint/libfprint/-/wikis/TOD) plugin
against a different libfprint fork, and RHEL's `libfprint` doesn't have TOD
support compiled in either).

## What this repo actually does

`install.sh`:

1. Detects your installed `libfprint` RPM version and clones the exact
   matching upstream git tag — this is the part that actually matters. The
   library's SONAME (`libfprint-2.so.2`) hasn't changed across many minor
   releases, which is a deliberate ABI-stability commitment from upstream,
   but the exact symbol set `fprintd` needs *has* grown over time (e.g.
   suspend/resume support). Building against a mismatched version causes
   `fprintd` to crash on startup with an undefined symbol error. Building
   the exact tag your system already has guarantees a match.
2. Grafts the `vfs0090` driver source into that tree (two small patches to
   `meson.build` register it — upstream never had this driver, so it needs
   introducing, not un-disabling).
3. Applies two one-line fixes to the driver source itself (see
   `patches/0002-vfs0090-driver-fixes.patch`):
   - `vfs0090.c` never included `config.h`, so its own `#if HAVE_PIXMAN`
     guard silently evaluated false, skipping an image-rescale step it
     should run.
   - `vfs0090.c` subclasses `FpDevice` directly rather than
     `FpImageDevice`, so it misses out on libfprint's automatic
     `features` flag detection — a newer libfprint asserts this is set,
     so without it `fprintd` segfaults on startup. One call to
     `fpi_device_class_auto_initialize_features()` fixes it.
4. Verifies the built library actually satisfies every symbol the
   installed `fprintd` binary needs before touching anything.
5. Installs the result to `/usr/local` (never touches the RPM-owned
   system `libfprint`) and points `fprintd` at it via a systemd drop-in
   environment variable — *not* `LD_LIBRARY_PATH` pointed at your home
   directory, because `fprintd`'s systemd unit has `ProtectHome=true`,
   which makes `/home` invisible to the sandboxed process. `/usr/local`
   stays readable under `ProtectSystem=strict` (which only blocks writes).
6. Enables `fprintd` to start at boot, via a second drop-in that gives
   the unit an `[Install]` section (it ships without one — it's meant to
   be purely D-Bus-activated). Without this, GDM's login screen will
   *never* offer the fingerprint option on a fresh boot: it checks
   whether `fprintd` is already running to decide whether to show the
   prompt, but doesn't itself trigger D-Bus activation and doesn't
   retry. On a cold boot nothing has touched `fprintd` yet at the moment
   the greeter draws, so it silently falls back to password-only —
   consistently, not intermittently. This doesn't touch PAM/polkit at
   all, just makes the daemon warm earlier.

None of this touches your system's `libfprint` RPM. A `dnf update` won't
conflict with it, and uninstalling is a matter of removing two systemd
drop-ins and one directory (`uninstall.sh` does this).

## Usage

```
git clone <this-repo>
cd vfs0090-rhel
./install.sh
```

It'll ask for `sudo` (to install missing `-devel` build dependencies, and
at the end to install the built library and the systemd drop-in). Then:

```
fprintd-enroll -f right-index-finger $USER
fprintd-verify $USER
```

If fingerprint auth isn't already enabled system-wide:

```
sudo authselect enable-feature with-fingerprint
```

After that, `sudo`, the lock screen, and GDM login all accept a touch on
the sensor — they go through PAM's `system-auth`, which `authselect`
already wires to `pam_fprintd.so`.

## Uninstalling

```
./uninstall.sh
```

Your enrolled fingerprints (`/var/lib/fprint`) are untouched by either
script.

## Known rough edges

**No obvious way to fall back to typing your password.** `system-auth`'s
`auth` stack has `pam_fprintd.so` as `sufficient` *before* `pam_unix.so`
(also `sufficient`), which is the textbook-correct order for "try
fingerprint, fall back to password on failure" — and this is confirmed
identical for `sudo` and the polkit "authenticate to make changes"
dialogs (both include `system-auth`). In practice, though, neither
pressing Enter nor waiting appears to reliably surface a usable password
prompt while the fingerprint prompt is active — this looks like it's
about how `pam_fprintd`'s prompt is implemented (it's tied to the actual
async USB verify call, not a normal text field reading your keystrokes),
not a PAM ordering bug. Still being pinned down; if you find the actual
reliable way to bail out to password, please open an issue.

## Troubleshooting

**"No upstream tag vX.Y.Z"** — your installed `libfprint` version doesn't
have a matching public tag on `gitlab.freedesktop.org` (this can happen
with a distro-specific point release). Check
`https://gitlab.freedesktop.org/libfprint/libfprint/-/tags` for the
closest available tag and re-run with:

```
git -C /path/to/manual/clone checkout <closest-tag>
```

adapting `install.sh`'s clone step, or open an issue with your
`rpm -q libfprint` output.

**Patch fails to apply** — upstream `libfprint`'s `meson.build` or the
driver source has moved on structurally since this was last updated
against them. Compare `patches/0001-*.patch` context against the current
file by hand; the change is small (register `vfs0090` in a driver-name
list and a helper-dependency map — see the patch itself for the exact
lines).

**Build succeeds but `fprintd` still crashes on startup** — run
`sudo journalctl -u fprintd -S -1min` and check for an
`undefined symbol` or `assertion failed` line; both are the kind of thing
this repo's `patches/` fix, meaning something about your libfprint version
has drifted further from what's pinned here. Compare against
`patches/0002-vfs0090-driver-fixes.patch` — the same two categories of fix
(missing `config.h`, missing `features` flag) are the most likely repeat
offenders after a libfprint API change.

**Sensor was previously used with Windows Hello** — some reports suggest
the sensor needs to be re-paired/initialized if Windows Hello was ever set
up on it. If enrollment fails outright (not just "no driver"), this is
worth investigating separately; it's not something this repo addresses.

## Tested against

- RHEL 10.2 (`libfprint-1.94.9-3.el10`, `fprintd-1.94.5-1.el10_0`)
- Sensor: `138a:0090` (bcdDevice `0164`)
- Driver source pinned at commit `252c98495791839b36fe5154f55ecca62df2e76a`
  of [3v1n0/libfprint-tod-vfs0090](https://github.com/3v1n0/libfprint-tod-vfs0090)

## License

`libfprint` and the `vfs0090` driver are both LGPL-2.1-or-later; this
repo's patches and scripts are released under the same license (see
`LICENSE`).
