#!/usr/bin/env python3
"""
Verify the AVBv1 boot signature in a signed boot/recovery partition image.

Mirrors what aboot's yellow path actually does: pulls the X.509 cert out of the
image's OWN signature block and verifies against that. So it needs no key or
keystore, and works on ANY image -- ours, a stock Palm one, or something pulled
off the device -- reporting whose key signed it.

If this says OK, the signature is cryptographically valid and any bootloader
rejection is a yellow-state fallthrough, not a signing problem. The signing
pipeline is deterministic: re-signing the same unsigned input produces
byte-identical output, so a re-flash will not "fix" an image that already
verifies here.

The printed fingerprint is what aboot shows on the yellow warning screen. It is
the tamper tripwire: an unexpected fingerprint means someone else signed this
image. (Such an image also cannot decrypt existing /data -- the boot key digest
feeds keymaster's Root of Trust. See sign-boot.py.)

Usage:
    /usr/bin/python3 scripts/boot-signing/scripts/verify-boot-sig.py [<boot.bin>] [<target>]

Default: flash-staging/boot.bin, target /boot (use /recovery for recovery.bin)
"""
import struct
import sys
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.x509 import load_der_x509_certificate


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


def der_tlv_len(buf, off):
    """Total encoded length (header + content) of the DER TLV starting at off."""
    n = buf[off + 1]
    if n < 0x80:
        return 2 + n
    n &= 0x7f
    return 2 + n + int.from_bytes(buf[off + 2:off + 2 + n], 'big')


def main():
    src    = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('flash-staging/boot.bin')
    target = sys.argv[2]       if len(sys.argv) > 2 else '/boot'

    data = src.read_bytes()
    if data[:8] != b'ANDROID!':
        sys.exit(f'ERROR: {src} is not an Android boot image')

    ks = struct.unpack_from('<I', data,  8)[0]
    rs = struct.unpack_from('<I', data, 16)[0]
    ps = struct.unpack_from('<I', data, 36)[0]
    def pages(n): return (n + ps - 1) // ps
    img_size = (1 + pages(ks) + pages(rs)) * ps

    sig_block = data[img_size:]
    if not sig_block or sig_block[0] != 0x30:
        sys.exit(f'ERROR: no DER SEQUENCE at img_size ({hex(img_size)}) — image is unsigned?')

    # Cert is the second element: skip the outer SEQUENCE header and the 3-byte
    # INTEGER version. Slice to its exact DER length -- the parser rejects
    # trailing data, and everything after it is trailing data.
    hdr = 4 if sig_block[1] == 0x82 else 2
    c0 = hdr + 3
    cert = load_der_x509_certificate(sig_block[c0:c0 + der_tlv_len(sig_block, c0)])

    idx = sig_block.find(b'\x04\x82\x01\x00')
    if idx < 0:
        sys.exit('ERROR: RSA OCTET STRING not found in sig block')
    rsa_sig = sig_block[idx + 4:idx + 4 + 256]

    try:
        cert.public_key().verify(
            rsa_sig,
            data[:img_size] + build_auth_attrs(target, img_size),
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
    except InvalidSignature:
        sys.exit(f'FAIL  {src}\n      signature does not verify against its own embedded cert '
                 f'(corrupt, or signed for a different target than {target})')

    sig_len  = len(sig_block.rstrip(b'\x00'))
    trailing = len(data) - img_size - sig_len
    print(f'OK  {src}')
    print(f'    target      = {target}')
    print(f'    img_size    = {hex(img_size)}, sig_len = {hex(sig_len)}, zeros = {hex(trailing)}')
    print(f'    signer      = {cert.subject.rfc4514_string()}')
    print(f'    fingerprint = {cert.fingerprint(hashes.SHA256()).hex(":").upper()}')


if __name__ == '__main__':
    main()
