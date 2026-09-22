// The render sandbox's whole program (WP-3.5).
//
// Runs with an opaque origin inside `<iframe sandbox="allow-scripts">`, so
// there is nothing here to protect: it cannot see the app's DOM, storage or
// session. What it must not do is turn its input into markup — every path
// below hands the payload to a library as a *string* and lets the library
// build the nodes.
;(() => {
  const out = document.getElementById('out')

  /** Reports our height so the embedder can size the frame to the content. */
  function reportHeight() {
    // `scrollHeight` on the content, not the body: the body is `overflow:
    // hidden`, so its own height would be whatever the frame already is and
    // the frame would never grow.
    const height = Math.ceil(out.getBoundingClientRect().height) + 4
    parent.postMessage({ conduit: 'size', height }, '*')
  }

  function fail(message) {
    out.textContent = ''
    const node = document.createElement('div')
    node.className = 'conduit-error'
    // `textContent`, so a malformed payload is shown rather than parsed.
    node.textContent = message
    out.appendChild(node)
    reportHeight()
  }

  const renderers = {
    math(payload) {
      if (typeof katex === 'undefined') throw new Error('katex is missing')
      out.textContent = ''
      // `throwOnError: false` renders the offending source in red rather
      // than leaving the block empty, which is what a half-streamed formula
      // looks like for as long as it is arriving.
      katex.render(String(payload.source), out, {
        displayMode: payload.display === true,
        throwOnError: false,
        // The single most important option here. With `trust` on, `\href`
        // and `\includegraphics` accept URLs from the payload, and the
        // payload is model output.
        trust: false,
        strict: false,
        maxSize: 50,
        maxExpand: 1000,
      })
    },
  }

  window.addEventListener('message', (event) => {
    // Only the embedder. A sandboxed frame has an opaque origin, so the
    // origin check that would normally go here is meaningless; identity of
    // the source window is the real one.
    if (event.source !== parent) return
    const data = event.data
    if (!data || data.conduit !== 'render') return
    const render = renderers[data.kind]
    if (!render) {
      fail('unsupported content: ' + String(data.kind))
      return
    }
    try {
      render(data)
      reportHeight()
    } catch (error) {
      fail(String(error && error.message ? error.message : error))
    }
  })

  // Tells the embedder the frame is listening. Messages sent before this
  // would be dropped, and the embedder cannot otherwise know when a frame
  // it just created has finished loading its scripts.
  parent.postMessage({ conduit: 'ready' }, '*')
})()
