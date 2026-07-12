#!/usr/bin/env python3
"""
Verify the AVBv1 boot signature in a signed boot partition image.

Usage:
    /usr/bin/python3 scripts/verify-boot-sig.py [<boot.bin>]

Default: flash-staging/boot-new.bin
"""
import struct
import sys
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.x509 import load_pem_x509_certificate

REPO_ROOT = Path(__file__).resolve().parent.parent


def enc_len(n):
    return bytes([n]) if n < 0x80 else bytes([0x82, n >> 8, n & 0xff])

def seq(b):
    return b'\x30' + enc_len(len(b)) + b

def build_auth_attrs(target, img_size):
    pb = target.encode('ascii')
    ps = b'\x13' + bytes([len(pb)]) + pb
    raw = img_size.to_bytes(4, 'big').lstrip(b'\x00') or b'\x00'
    if raw[0] & 0x80:
        raw = b'\x00' + raw
    return seq(ps + b'\x02' + bytes([len(raw)]) + raw)


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO_ROOT / 'flash-staging/boot-new.bin'
    cert = load_pem_x509_certificate((REPO_ROOT / 'keys/verity.x509.pem').read_bytes())

    data = src.read_bytes()
    assert data[:8] == b'ANDROID!', 'not an Android boot image'

    ks = struct.unpack_from('<I', data,  8)[0]
    rs = struct.unpack_from('<I', data, 16)[0]
    ps = struct.unpack_from('<I', data, 36)[0]
    def pages(n): return (n + ps - 1) // ps
    img_size = (1 + pages(ks) + pages(rs)) * ps

    sig_block = data[img_size:]
    assert sig_block[0] == 0x30, f'expected SEQUENCE at img_size, got {hex(sig_block[0])}'

    idx = sig_block.find(b'\x04\x82\x01\x00')
    assert idx >= 0, 'RSA OCTET STRING not found in sig block'
    rsa_sig = sig_block[idx+4:idx+4+256]

    auth_attrs = build_auth_attrs('/boot', img_size)

    cert.public_key().verify(rsa_sig, data[:img_size] + auth_attrs, padding.PKCS1v15(), hashes.SHA256())

    sig_len = len(data[img_size:].rstrip(b'\x00'))
    trailing = len(data) - img_size - sig_len
    print(f'OK  {src}')
    print(f'    img_size = {hex(img_size)}, sig_len = {hex(sig_len)}, zeros = {hex(trailing)}')


if __name__ == '__main__':
    main()
