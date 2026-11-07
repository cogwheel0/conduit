"""Synthetic native-frame and RFB endpoints. Never captures the host screen.

Uses Pillow and websockets from the isolated Open Terminal review environment.
"""
import asyncio
import io
import json
import struct

from PIL import Image, ImageDraw
from websockets.asyncio.server import serve

events = []
WIDTH, HEIGHT = 320, 240


def pixels(changed=False):
    image = Image.new('RGB', (WIDTH, HEIGHT), '#263e37')
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((30, 35, 290, 205), radius=12, fill='#f4f2e8')
    draw.text((48, 55), 'STUDIO DESKTOP', fill='#263e37')
    draw.rectangle((48, 95, 270, 175), fill='#cb7966' if changed else '#a0b99e')
    return image


async def native(ws):
    async def frame(changed=False):
        stream = io.BytesIO()
        pixels(changed).save(stream, 'JPEG')
        await ws.send(struct.pack('!6H', WIDTH, HEIGHT, 0, 0, WIDTH, HEIGHT) + stream.getvalue())
    await frame()
    async for raw in ws:
        message = json.loads(raw)
        if message['type'] in ('mouse', 'key', 'paste', 'release'):
            events.append(message)
            if message['type'] == 'mouse' and message.get('buttons'):
                await frame(True)


async def vnc(ws):
    buffer = bytearray()

    async def read(count):
        while len(buffer) < count:
            buffer.extend(await ws.recv())
        result = bytes(buffer[:count])
        del buffer[:count]
        return result

    await ws.send(b'RFB 003.008\n')
    assert await read(12) == b'RFB 003.008\n'
    await ws.send(b'\x01\x01')
    assert await read(1) == b'\x01'
    await ws.send(b'\x00\x00\x00\x00')
    await read(1)
    name = b'Synthetic studio'
    await ws.send(struct.pack('!HHBBBBHHHBBB3xI', WIDTH, HEIGHT,
        32, 24, 0, 1, 255, 255, 255, 16, 8, 0, len(name)) + name)
    changed = False
    while True:
        kind = (await read(1))[0]
        if kind == 0:
            await read(19)
        elif kind == 2:
            count = struct.unpack('!xH', await read(3))[0]
            await read(count * 4)
        elif kind == 3:
            await read(9)
            data = pixels(changed).tobytes('raw', 'BGRX')
            await ws.send(struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, WIDTH, HEIGHT, 0) + data)
            await asyncio.sleep(.04)
        elif kind == 4:
            data = await read(7)
            events.append({'type': 'key', 'down': data[0], 'keysym': struct.unpack('!I', data[3:])[0]})
        elif kind == 5:
            mask, x, y = struct.unpack('!BHH', await read(5))
            events.append({'type': 'mouse', 'buttons': mask, 'x': x, 'y': y})
            changed = changed or mask != 0
        elif kind == 6:
            length = struct.unpack('!3xI', await read(7))[0]
            # This fixture advertises only legacy clipboard support.
            assert length < 65536
            events.append({'type': 'paste', 'text': (await read(length)).decode('utf-8')})
        elif kind == 248:
            # noVNC continuous-updates extension is not advertised here.
            await read(8)
        else:
            raise AssertionError(f'Unexpected RFB message {kind}')


async def handle(ws):
    if ws.request.path == '/events':
        await ws.send(json.dumps(events))
        return
    auth = json.loads(await ws.recv())
    assert auth == {'type': 'auth', 'token': 'fixture-key', 'chat_id': 'fixture-chat'}
    if ws.request.path == '/frames':
        await native(ws)
    else:
        await vnc(ws)


async def main():
    async with serve(handle, '127.0.0.1', 0) as server:
        print(server.sockets[0].getsockname()[1], flush=True)
        await asyncio.Future()


if __name__ == '__main__':
    asyncio.run(main())
