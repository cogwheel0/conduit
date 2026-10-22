#!/usr/bin/env python3
"""Install only the pinned English q8 + Zoey build assets, verifying every byte."""
import hashlib
import os
from pathlib import Path
import shutil
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'android/app/src/main/assets/phonon'
MODEL = 'https://huggingface.co/gradium/phonon-31m-en/resolve/92741c5b07d085ff840e26fea8ce43110b87852f/'
VOICES = 'https://huggingface.co/gradium/phonon-voices/resolve/0ee17205f254b5abc43b266c8a0f215565c352f7/'
FILES = {
 'model.q8.gguf': (MODEL, 64512352, 'a7d9aad2cd6dc66473f24a08bc6d2939030ef4d751ef82349361fbef3272dbae'),
 'config.json': (MODEL, 4634, 'b5d0f88353638370d94035b7d73d7d6577c0554d78f8d7ecfd40490aae39ae85'),
 'tokenizer.json': (MODEL, 277967, '691a00068fa7b989f2f3e5ae5daa2d1a5bb319f2d5360deafcfb19a8bb6e7936'),
 'voices/NbpkqMVS3CJeq2j8.safetensors': (VOICES, 256136, '97c7f8c253413574406ab80dd23f49c3ebb2517163b00a9bf86b9c4cf43e7e23'),
}

def verified(path, size, digest):
 return path.is_file() and path.stat().st_size == size and hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() == digest

for relative, (base, size, digest) in FILES.items():
 target = DEST / relative
 if verified(target, size, digest):
  continue
 target.parent.mkdir(parents=True, exist_ok=True)
 staging = target.with_suffix(target.suffix + '.partial')
 cache = Path(sys.argv[1]) / relative if len(sys.argv) > 1 else None
 if cache and verified(cache, size, digest):
  shutil.copyfile(cache, staging)
 else:
  with urllib.request.urlopen(base + relative, timeout=90) as response, staging.open('wb') as output:
   shutil.copyfileobj(response, output)
 if not verified(staging, size, digest):
  staging.unlink(missing_ok=True)
  raise SystemExit(f'Integrity failure: {relative}')
 os.replace(staging, target)
 print(f'Verified {relative}: {size} bytes')

for license_name in ('LICENSE-APACHE', 'LICENSE-MIT'):
 target = DEST / license_name
 if not target.is_file():
  with urllib.request.urlopen('https://raw.githubusercontent.com/gradium-ai/xn-ptts/49b9033e44ab0fbb935973eca3213757644d1bbb/' + license_name, timeout=30) as response:
   target.write_bytes(response.read())
(DEST / 'ATTRIBUTION.txt').write_text(
 'Phonon CPU runtime: gradium-ai/xn-ptts@49b9033e44ab0fbb935973eca3213757644d1bbb; MIT OR Apache-2.0.\n'
 'English 31M q8: gradium/phonon-31m-en@92741c5b07d085ff840e26fea8ce43110b87852f; Apache-2.0.\n'
 'Zoey NbpkqMVS3CJeq2j8: gradium/phonon-voices@0ee17205f254b5abc43b266c8a0f215565c352f7; Apache-2.0.\n'
 'JNA 5.17.0: Java Native Access contributors; Apache-2.0 license option.\n')
