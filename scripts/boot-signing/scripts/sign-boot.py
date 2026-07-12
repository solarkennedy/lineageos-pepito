#!/usr/bin/env python3
"""
Build and sign a Palm PVG-100 boot partition image using the Android dev key.

The bootloader implements AVBv1 (BOOT.BF.3.3 boot_verifier).  It reads a DER
SEQUENCE appended at img_size and verifies it with the trusted certificate
stored in the partition table.  The Disable_Dm-Verity zip ships the private key
(keys/verity.pk8) and matching certificate (keys/verity.x509.pem) that the
bootloader trusts, producing a yellow-state boot.

Signature structure (AVBv1 BootSignature):
    SEQUENCE {
        INTEGER version = 1
        SEQUENCE certificate (DER, verbatim from verity.x509.pem)
        SEQUENCE AlgorithmIdentifier { OID sha1WithRSAEncryption, NULL }
        SEQUENCE auth_attrs {
            PrintableString "/boot"
            INTEGER img_size
        }
        OCTET STRING rsa_sig (256 bytes)
    }

Signing formula: RSA-PKCS1v15-SHA256(boot_image[:img_size] + auth_attrs_der)
Note: the OID says sha1 but LK doesn't enforce it; actual hash is SHA256.

Header patches applied before signing:
  - id field (0x240, 20 bytes): SHA1 over kernel+ramdisk+second (mkbootimg v0)
  - os_version (0x2C, 4 bytes): restored from stock to match bootloader expectation

Usage:
    /usr/bin/python3 scripts/sign-boot.py [<input_img> [<output_img>]]

Defaults:
    input:  flash-staging/boot_unsigned.img
    output: flash-staging/boot.bin
"""
import hashlib
import struct
import sys
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.x509 import load_pem_x509_certificate

REPO_ROOT      = Path(__file__).resolve().parent.parent
KEYS_DIR       = REPO_ROOT / 'keys'
PARTITION_SIZE = 0x4000000   # 64 MB boot partition
ID_OFFSET      = 0x240       # 20-byte mkbootimg SHA1 id
OSVER_OFFSET   = 0x2c        # 4-byte os_version
STOCK_OSVER    = bytes.fromhex('49010410')

# AlgorithmIdentifier: sha1WithRSAEncryption OID + NULL parameter
ALGO_ID = bytes.fromhex('300d06092a864886f70d0101050500')


def enc_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    return bytes([0x82, n >> 8, n & 0xff])


def seq(b: bytes) -> bytes:
    return b'\x30' + enc_len(len(b)) + b


def build_auth_attrs(target: str, img_size: int) -> bytes:
    ps_bytes = target.encode('ascii')
    printable_str = b'\x13' + bytes([len(ps_bytes)]) + ps_bytes

    raw = img_size.to_bytes(4, 'big').lstrip(b'\x00') or b'\x00'
    if raw[0] & 0x80:
        raw = b'\x00' + raw
    integer = b'\x02' + bytes([len(raw)]) + raw

    return seq(printable_str + integer)


def compute_id(img: bytes) -> bytes:
    """SHA1 over (kernel|ksize|ramdisk|rsize|second|ssize), matching mkbootimg v0."""
    ks = struct.unpack_from('<I', img,  8)[0]
    rs = struct.unpack_from('<I', img, 16)[0]
    ss = struct.unpack_from('<I', img, 24)[0]
    ps = struct.unpack_from('<I', img, 36)[0]

    def pages(n): return (n + ps - 1) // ps
    k_off = ps
    r_off = k_off + pages(ks) * ps
    s_off = r_off + pages(rs) * ps

    sha = hashlib.sha1()
    sha.update(img[k_off:k_off + ks]); sha.update(struct.pack('<I', ks))
    sha.update(img[r_off:r_off + rs]); sha.update(struct.pack('<I', rs))
    sha.update(img[s_off:s_off + ss]); sha.update(struct.pack('<I', ss))
    return sha.digest()


def compute_img_size(img: bytes) -> int:
    ks = struct.unpack_from('<I', img,  8)[0]
    rs = struct.unpack_from('<I', img, 16)[0]
    ps = struct.unpack_from('<I', img, 36)[0]
    def pages(n): return (n + ps - 1) // ps
    return (1 + pages(ks) + pages(rs)) * ps


def main():
    src    = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO_ROOT / 'flash-staging/boot_unsigned.img'
    dest   = Path(sys.argv[2]) if len(sys.argv) > 2 else REPO_ROOT / 'flash-staging/boot.bin'
    target = sys.argv[3]       if len(sys.argv) > 3 else '/boot'

    pk8_path  = KEYS_DIR / 'verity.pk8'
    cert_path = KEYS_DIR / 'verity.x509.pem'

    private_key = serialization.load_der_private_key(pk8_path.read_bytes(), password=None)
    cert        = load_pem_x509_certificate(cert_path.read_bytes())
    cert_der    = cert.public_bytes(serialization.Encoding.DER)

    img = bytearray(src.read_bytes())
    assert img[:8] == b'ANDROID!', 'not an Android boot image'

    img_id = compute_id(bytes(img))
    img[ID_OFFSET:ID_OFFSET + 20] = img_id
    img[OSVER_OFFSET:OSVER_OFFSET + 4] = STOCK_OSVER

    img_size   = compute_img_size(bytes(img))
    auth_attrs = build_auth_attrs(target, img_size)

    rsa_sig = private_key.sign(
        bytes(img[:img_size]) + auth_attrs,
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
    assert len(rsa_sig) == 256, f'unexpected RSA sig length: {len(rsa_sig)}'

    version    = b'\x02\x01\x01'
    sig_octet  = b'\x04\x82\x01\x00' + rsa_sig
    sig_block  = seq(version + cert_der + ALGO_ID + auth_attrs + sig_octet)

    sig_len    = len(sig_block)
    padding_sz = PARTITION_SIZE - img_size - sig_len
    assert padding_sz >= 0, f'image ({hex(img_size)}) + sig ({hex(sig_len)}) exceeds partition size'

    partition = bytes(img[:img_size]) + sig_block + b'\x00' * padding_sz
    assert len(partition) == PARTITION_SIZE

    dest.write_bytes(partition)
    print(f'id         = {img_id.hex()}')
    print(f'os_version = {STOCK_OSVER.hex()}')
    print(f'img_size   = {hex(img_size)}')
    print(f'sig_len    = {hex(sig_len)}')
    print(f'wrote {dest}')


if __name__ == '__main__':
    main()
