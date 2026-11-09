// Optional desktop playback. No microphone, persistence, or automatic restart.
export function createAudio(report) {
  const mime = 'audio/webm; codecs="opus"';
  let current = null;
  const mediaSource = () => [globalThis.MediaSource, globalThis.ManagedMediaSource]
    .find(source => source?.isTypeSupported(mime) === true);
  const supported = () => !!mediaSource();
  function stop(failed = false) {
    const session = current;
    current = null;
    if (session) {
      if (session.socket) {
        session.socket.onopen = session.socket.onmessage = session.socket.onclose = null;
        session.socket.close();
      }
      if (session.buffer) session.buffer.onupdateend = session.buffer.onerror = null;
      session.player.onerror = null;
      session.player.pause();
      session.player.removeAttribute('src');
      session.player.load();
      URL.revokeObjectURL(session.url);
    }
    report({enabled: false, failed});
  }
  function start(config) {
    stop();
    if (!config.audio || !supported()) { stop(true); return; }
    const session = {player: new Audio(), source: new (mediaSource())(), queue: [], bytes: 0};
    current = session;
    const fail = () => { if (current === session) stop(true); };
    const append = () => {
      if (current !== session || !session.buffer || session.buffer.updating) return;
      try {
        const ranges = session.buffer.buffered;
        if (ranges.length) {
          const end = ranges.end(ranges.length - 1);
          if (end - session.player.currentTime > .5) session.player.currentTime = Math.max(0, end - .15);
          if (session.player.currentTime - ranges.start(0) > 10) {
            session.buffer.remove(0, session.player.currentTime - 5);
            return;
          }
        }
        const packet = session.queue.shift();
        if (packet) { session.bytes -= packet.byteLength; session.buffer.appendBuffer(packet); }
      } catch (_) { fail(); }
    };
    try {
      session.url = URL.createObjectURL(session.source);
      session.player.disableRemotePlayback = true;
      session.player.src = session.url;
      session.player.onerror = fail;
      session.source.addEventListener('sourceopen', () => {
        if (current !== session) return;
        try {
          session.buffer = session.source.addSourceBuffer(mime);
          session.buffer.onupdateend = append;
          session.buffer.onerror = fail;
          const ws = session.socket = new WebSocket(config.url.replace(/\/stream$/, '/audio'));
          ws.binaryType = 'arraybuffer';
          ws.onopen = () => {
            if (current !== session) return;
            ws.send(JSON.stringify({type: 'auth', token: config.token, chat_id: config.chatId}));
            report({enabled: true, failed: false});
          };
          ws.onmessage = event => {
            if (current !== session) return;
            if (!(event.data instanceof ArrayBuffer) || !event.data.byteLength) { fail(); return; }
            session.bytes += event.data.byteLength;
            if (session.bytes > 65536) { fail(); return; }
            session.queue.push(event.data);
            append();
          };
          ws.onclose = fail;
        } catch (_) { fail(); }
      }, {once: true});
      session.player.play().catch(fail);
    } catch (_) { fail(); }
  }
  return {start, stop, supported};
}
