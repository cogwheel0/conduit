// Open Terminal's patch header is six unsigned big-endian 16-bit values.
export function patchHeader(buffer) {
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength <= 12) return null;
  const view = new DataView(buffer);
  const [width, height, x, y, patchWidth, patchHeight] =
    Array.from({length: 6}, (_, i) => view.getUint16(i * 2));
  if (!width || !height || width > 8192 || height > 8192 ||
      !patchWidth || !patchHeight || x + patchWidth > width ||
      y + patchHeight > height) return null;
  return {width, height, x, y, patchWidth, patchHeight};
}

export function remotePoint(event, bounds, width, height) {
  return {
    x: Math.max(0, Math.min(width - 1, Math.round((event.clientX - bounds.left) * width / bounds.width))),
    y: Math.max(0, Math.min(height - 1, Math.round((event.clientY - bounds.top) * height / bounds.height))),
  };
}

export function canSendInput(controlling, connected, visible) {
  return controlling && connected && visible;
}
