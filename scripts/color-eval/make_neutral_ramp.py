"""Writes the neutral test image: a 0-255 grey ramp over six flat grey patches (320x160).
A correct pipeline keeps it colourless (max OKLab/Lab chroma about 0)."""
import sys
import numpy as np
from PIL import Image

w, h = 320, 160
a = np.zeros((h, w, 3), dtype=np.uint8)
a[:h // 2] = np.linspace(0, 255, w).astype(np.uint8)[None, :, None]
for i, v in enumerate([20, 60, 110, 160, 210, 245]):
    a[h // 2:, i * w // 6:(i + 1) * w // 6] = v
for out in sys.argv[1:]:
    Image.fromarray(a).save(out)
