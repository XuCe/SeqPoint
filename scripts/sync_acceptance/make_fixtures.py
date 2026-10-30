"""Create valid, incompressible transport fixtures; no user files are used."""
import hashlib
import pathlib
import random
import struct
import subprocess
import sys
import wave
import zlib

root = pathlib.Path(sys.argv[1]).resolve().parent
if not root.name.startswith('seqpoint-native-sync-'):
    raise SystemExit('Expected acceptance setup.json path')
rng = random.Random(20261030)
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
width = height = 2560
pixels = b''.join(b'\0' + rng.randbytes(width * 3) for _ in range(height))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(pixels, 0)) + chunk(b'IEND', b'')
(root / 'large.png').write_bytes(png)
with wave.open(str(root / 'tone.wav'), 'wb') as wav:
    wav.setparams((1, 2, 44100, 44100, 'NONE', 'not compressed'))
    wav.writeframes(b'\0\0' * 44100)
subprocess.run(['/usr/bin/afconvert', '-f', 'm4af', '-d', 'aac', str(root / 'tone.wav'), str(root / 'large.m4a')], check=True, capture_output=True)
# A valid MP4 free box keeps playback intact while exercising 40 MiB of random original bytes.
with (root / 'large.m4a').open('ab') as audio:
    audio.write(struct.pack('>I', 40 * 1024 * 1024 + 8) + b'free')
    for _ in range(40):
        audio.write(rng.randbytes(1024 * 1024))
for name in ('large.png', 'large.m4a'):
    data = (root / name).read_bytes()
    print(name, len(data), hashlib.sha256(data).hexdigest())
