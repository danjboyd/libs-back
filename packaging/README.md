# danjboyd/libs-back: the carry branch

`carry` is GNUstep's libs-back 0.32.0 (`back-0_32_0`, the release MSYS2
packages) with the changes our Windows apps need before GNUstep has them.
It is what our MSIs ship. Every change here is also a branch on upstream
master, meant to be sent upstream once it has proven itself; nothing is
sent without Dan's sign-off (the upstream policy in
plugins-themes-Adwaita's `Docs/UPSTREAM_POLICY.md`).

## What it carries

| Change | Topic branch (on upstream master) | Upstream |
| --- | --- | --- |
| win32pbs: images between the Windows clipboard and gpbs | `win32pbs-images` | gnustep/libs-back#246, open |
| win32: the gui draws a titled window's caption (`GSBackClientDrawsCaptions`, caption regions, Snap Layouts); the WinUI theme's title bar (plugins-themes-winuitheme#83) | `win32-client-caption` | not sent |
| win32: `-setmaxsize::` leaves the maximize box as the window's style means it, no longer toggling it or giving one to windows that can't be resized (plugins-themes-winuitheme#67) | `win32-setmaxsize` | not sent |
| win32: `-setShadow::` gives a borderless window DWM's shadow (and Windows 11's rounding): menus, tool tips and flyouts (plugins-themes-winuitheme#39) | `win32-popup-shadows` | not sent |
| win32: per-monitor DPI awareness with the `GSBackDPIAware` default: sharp at every display scale, each monitor's resolution, `WM_DPICHANGED` (keeping a window the gui placed itself), hinted glyph metrics off as with `GSScaleFactor`, and for a system DPI aware app whose screen's resolution isn't 72 (plugins-themes-winuitheme#105, ScreenshotTool #306) | `win32-per-monitor-dpi` | not sent |
| win32: each monitor's frame flipped against the primary's height, as window coordinates are, so windows on a monitor shorter than the primary (or not level with it) find their screen and its scale (plugins-themes-winuitheme#105) | `win32-monitor-frames` | not sent |

## The package

`packaging/msys2/PKGBUILD` is MSYS2's `mingw-w64-gnustep-back` recipe,
building this checkout. Its version, `0.32.0.N`, is newer than MSYS2's
`0.32.0`, so pacman keeps it over the stock package (until MSYS2 moves to a
later release: then rebase `carry` on it).

    cd packaging/msys2
    MINGW_ARCH=clang64 makepkg-mingw -Cf --nocheck
    pacman -U mingw-w64-clang-x86_64-gnustep-back-0.32.0.N-1-any.pkg.tar.zst

A tag `carry-0.32.0.N` builds it in GitHub Actions
(`.github/workflows/msys2-package.yml`) and attaches it to a release of
that name; gnustep-packager's workflow installs it from there. Raise N
(the PKGBUILD's `pkgver`) for each release.

## Keeping it current

- A change goes on its topic branch first (based on `upstream/master`),
  then is cherry-picked onto `carry`.
- When GNUstep releases, rebase the topic branches on upstream master,
  and rebuild `carry` on the new release tag.
- When a change is merged upstream and released, it leaves `carry`.

The source of each released package is its tag here, which satisfies the
LGPL for the MSIs that ship it.
