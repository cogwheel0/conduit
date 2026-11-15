# Preview scripts

Bundled into the app for the code-block Preview window
(`src/views/chat/preview.rs`) and the inline diagram renderer
(`src/views/chat/diagram.rs`), which run with no network access:

- `mermaid.min.js`: mermaid 12.2.0 from npm (`package/dist/mermaid.min.js`),
  MIT (`MERMAID-LICENSE`).
  - Tarball integrity
    `sha512-w7nr/SFrLO7BaVTs3dQTvYSV6nYSBj0Yy9DjBhsIJtAcHqRzXSq4Pg32ujHZ/AdWsAMNEvvhbm5dt9E2tOiHzw==`,
    checked against the npm registry when it was added.
  - SHA-256 of the file:
    `a8a6a6f805b074a8261a2825c86f99c8054acb3b35f50bb7e24a4f9f2c3c3b9f`.
    A unit test (`the_bundled_mermaid_is_the_pinned_one` in `preview.rs`)
    fails when the file and this line disagree, so an update changes both.
- Chart.js comes from the repository's `assets/chartjs.min.js` (v4.5.0, MIT),
  the copy the mobile app already ships.

The repository's `third_party/mermaid` is a Dart port with no JavaScript, so
the browser build is kept here. It is committed rather than downloaded at
build time so that every checkout builds offline and the same way.

To update: take `package/dist/mermaid.min.js` from the new release's npm
tarball (check the tarball's integrity against the registry), replace the
file, `MERMAID-LICENSE` if it changed, and the version, integrity and
SHA-256 above; the notices (`packaging/notices/notices.py`) read the
version from this file.
