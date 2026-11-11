// Clipboard ownership changes can clear X11 selections before a paste arrives.
// Send literal keysyms so typing replaces the selected text in the remote app.
export async function typeRfbText(client, text, canType) {
  let sent = 0;
  for (const char of text.replace(/\r\n?/g, '\n')) {
    if (!canType()) return;
    const point = char.codePointAt(0);
    const keysym = char === '\n' ? 0xff0d : char === '\t' ? 0xff09 :
      point <= 0xff ? point : 0x01000000 | point;
    client.sendKey(keysym, null);
    // Let Watch, backgrounding and disconnection cancel a long insertion.
    if (++sent % 128 === 0) await new Promise(resolve => setTimeout(resolve, 0));
  }
}
