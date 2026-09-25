// The render sandbox's whole program.
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

  // And again whenever the drawing changes size. KaTeX's fonts can arrive
  // after it has drawn, so the first measurement is of a fallback font and a
  // formula ended up a pixel taller than its frame. Nothing to report until
  // something has been drawn.
  new ResizeObserver(() => {
    if (out.childNodes.length > 0) reportHeight()
  }).observe(out)

  function fail(message) {
    out.textContent = ''
    const node = document.createElement('div')
    node.className = 'conduit-error'
    // `textContent`, so a malformed payload is shown rather than parsed.
    node.textContent = message
    out.appendChild(node)
    reportHeight()
  }

  /// Loads a vendored library on first use, once.
  ///
  /// Mermaid alone is five megabytes. Loading it eagerly would mean every
  /// inline formula -- the common case by a wide margin -- parsing it for
  /// nothing. A `<script>` added here is still governed by this document's
  /// `script-src app:`, so it can only ever fetch our own files.
  const loaded = {}
  function load(src) {
    if (loaded[src]) return loaded[src]
    loaded[src] = new Promise((resolve, reject) => {
      const tag = document.createElement('script')
      tag.src = src
      tag.onload = () => resolve()
      tag.onerror = () => reject(new Error('could not load ' + src))
      document.head.appendChild(tag)
    })
    return loaded[src]
  }

  /// Guards a payload that must be JSON.
  ///
  /// `JSON.parse`, never `eval` or `new Function`: a chart spec is model
  /// output, and the whole point of this frame is that model output is
  /// data here.
  function parseJson(source, what) {
    try {
      return JSON.parse(String(source))
    } catch (error) {
      throw new Error(what + ' is not valid JSON: ' + error.message)
    }
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

    async mermaid(payload) {
      await load('/vendor/mermaid/mermaid.min.js')
      out.textContent = ''
      window.mermaid.initialize({
        startOnLoad: false,
        // Mermaid's own sanitiser, on top of this frame's isolation. It is
        // what stops a diagram label from carrying markup into the SVG.
        securityLevel: 'strict',
        htmlLabels: false,
        theme: payload.dark === true ? 'dark' : 'default',
        fontFamily: 'inherit',
      })
      const id = 'mermaid-' + Math.random().toString(36).slice(2)
      const { svg } = await window.mermaid.render(id, String(payload.source))
      // The one `innerHTML` in the app, and the reason it is acceptable is
      // local: this document has an opaque origin, no network, and nothing
      // worth reaching. The string is Mermaid's own output from a diagram
      // it parsed and sanitised, not the model's text.
      out.innerHTML = svg
    },

    async chart(payload) {
      await load('/vendor/chart.js/chart.umd.js')
      const config = parseJson(payload.source, 'chart')
      out.textContent = ''
      const canvas = document.createElement('canvas')
      // A chart has no intrinsic height, so it needs one before Chart.js
      // measures; the embedder is told the result either way.
      canvas.style.width = '100%'
      canvas.style.height = '260px'
      out.appendChild(canvas)
      config.options = Object.assign({}, config.options, {
        responsive: true,
        maintainAspectRatio: false,
        // Every frame would otherwise animate on arrival, and a streaming
        // reply re-renders the chart on each delta.
        animation: false,
      })
      new window.Chart(canvas, config)
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
    // Renderers may be async -- mermaid and chart fetch their library on
    // first use -- so both paths go through a promise.
    Promise.resolve()
      .then(() => render(data))
      .then(reportHeight)
      .catch((error) => {
        fail(String(error && error.message ? error.message : error))
      })
  })

  // Tells the embedder the frame is listening. Messages sent before this
  // would be dropped, and the embedder cannot otherwise know when a frame
  // it just created has finished loading its scripts.
  parent.postMessage({ conduit: 'ready' }, '*')
})()
