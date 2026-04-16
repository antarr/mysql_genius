#!/usr/bin/env python3
"""Generate a simple app icon for MySQL Genius (blue database cylinder)."""
import sys
import struct
import zlib
import os

def create_png(width, height):
    """Create a simple blue database icon as PNG bytes."""
    pixels = []
    cx, cy = width / 2, height / 2
    r = min(width, height) * 0.38

    for y in range(height):
        row = []
        for x in range(width):
            dx = (x - cx) / r
            dy = (y - cy) / (r * 1.6)

            # Draw a simplified database cylinder shape
            in_body = abs(dx) <= 1.0 and -0.8 <= dy <= 0.8
            # Top ellipse
            top_e = dx * dx + ((y - cy * 0.6) / (r * 0.35)) ** 2
            # Bottom ellipse
            bot_e = dx * dx + ((y - cy * 1.35) / (r * 0.35)) ** 2
            # Middle ellipse (decorative ring)
            mid_e = dx * dx + ((y - cy * 1.0) / (r * 0.35)) ** 2

            if top_e <= 1.0:
                # Top face - lighter blue
                t = top_e
                cr = int(80 + 40 * t)
                cg = int(160 + 60 * t)
                cb = int(255 - 20 * t)
                ca = 255
            elif in_body and (cy * 0.6 + r * 0.35) <= y <= (cy * 1.35 + r * 0.35):
                # Cylinder body - gradient blue
                shade = 0.7 + 0.3 * (1.0 - abs(dx))
                cr = int(50 * shade)
                cg = int(120 * shade)
                cb = int(220 * shade)
                ca = 255
                # Middle ring highlight
                if mid_e <= 1.15 and mid_e >= 0.85:
                    cr = int(cr * 1.3)
                    cg = int(cg * 1.3)
                    cb = min(255, int(cb * 1.2))
            elif bot_e <= 1.0 and y >= cy * 1.35:
                # Bottom face edge
                shade = 0.5 + 0.3 * (1.0 - bot_e)
                cr = int(40 * shade)
                cg = int(100 * shade)
                cb = int(200 * shade)
                ca = 255
            else:
                cr, cg, cb, ca = 0, 0, 0, 0

            cr = max(0, min(255, cr))
            cg = max(0, min(255, cg))
            cb = max(0, min(255, cb))
            row.extend([cr, cg, cb, ca])
        pixels.append(bytes([0] + row))  # filter byte + row

    raw = b"".join(pixels)

    def chunk(ctype, data):
        c = ctype + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def main():
    iconset_dir = sys.argv[1]
    sizes = [16, 32, 64, 128, 256, 512]

    for size in sizes:
        png_data = create_png(size, size)

        path = os.path.join(iconset_dir, f"icon_{size}x{size}.png")
        with open(path, "wb") as f:
            f.write(png_data)

        # @2x variant (previous size at double resolution)
        if size >= 32:
            half = size // 2
            path2x = os.path.join(iconset_dir, f"icon_{half}x{half}@2x.png")
            with open(path2x, "wb") as f:
                f.write(png_data)

    # 512@2x = 1024
    png_data = create_png(1024, 1024)
    with open(os.path.join(iconset_dir, "icon_512x512@2x.png"), "wb") as f:
        f.write(png_data)


if __name__ == "__main__":
    main()
