"""Image sniffing and upload guard rails.

Trusting the ``Content-Type`` header of a multipart part is a classic upload
vulnerability: it is attacker-controlled.  We therefore identify the file by
its magic bytes.  (Python 3.13 removed ``imghdr`` from the stdlib, so a small
explicit table is both future-proof and easier to audit.)
"""

from __future__ import annotations

from dataclasses import dataclass

from fastapi import UploadFile

from app.core.errors import AvatarTooLargeError, UnsupportedAvatarTypeError

_CHUNK = 64 * 1024  # 64 KiB streaming chunks


@dataclass(frozen=True, slots=True)
class ImageKind:
    """Result of a successful sniff."""

    media_type: str
    extension: str


def sniff_image(payload: bytes) -> ImageKind | None:
    """Identify an image from its header, or return None if unknown."""
    if payload.startswith(b"\x89PNG\r\n\x1a\n"):
        return ImageKind("image/png", ".png")
    if payload.startswith(b"\xff\xd8\xff"):
        return ImageKind("image/jpeg", ".jpg")
    if payload.startswith((b"GIF87a", b"GIF89a")):
        return ImageKind("image/gif", ".gif")
    # WebP is a RIFF container: "RIFF" + 4 size bytes + "WEBP".
    if payload[:4] == b"RIFF" and payload[8:12] == b"WEBP":
        return ImageKind("image/webp", ".webp")
    return None


async def read_limited(upload: UploadFile, max_bytes: int) -> bytes:
    """Read an upload into memory, refusing anything over ``max_bytes``.

    Reading in chunks means a 5 GB request is rejected after the first chunk
    over the limit instead of being fully buffered first.  For much larger
    files the right answer is a browser-direct upload with an S3 presigned POST;
    for 2 MiB avatars, in-memory is simpler and fast.
    """
    buffer = bytearray()
    while chunk := await upload.read(_CHUNK):
        buffer.extend(chunk)
        if len(buffer) > max_bytes:
            raise AvatarTooLargeError(f"Avatar must not exceed {max_bytes // 1024} KiB.")
    if not buffer:
        raise UnsupportedAvatarTypeError("The uploaded avatar file is empty.")
    return bytes(buffer)
