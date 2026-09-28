# Conduit Desktop packages

Manifests for the package managers that carry Conduit Desktop.
Each names one release: `update-manifests.mjs` sets the version and the
artifacts' SHA-256 sums from a release's files, after
`release-desktop.yml` has published them.

```sh
node desktop/packaging/update-manifests.mjs 0.2.0 path/to/downloaded/artifacts
```

| Manager  | File                                             | Submitted to              |
|----------|--------------------------------------------------|---------------------------|
| Homebrew | `homebrew/conduit.rb`                            | a tap, or homebrew-cask   |
| winget   | `winget/cogwheel.Conduit.yaml`                   | microsoft/winget-pkgs     |
| AUR      | `aur/PKGBUILD`                                   | aur.archlinux.org         |
| Flathub  | `flathub/app.cogwheel.conduit.desktop.yml`       | flathub/flathub           |

The sums are placeholders (`0` × 64) until the first public release. Until
the desktop joins the `v*` release line, `scripts/release.sh`
leaves these alone; after it, it runs `update-manifests.mjs` too.
