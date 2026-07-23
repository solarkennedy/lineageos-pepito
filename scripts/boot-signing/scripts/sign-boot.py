#!/usr/bin/env python3
"""
Build and sign a Palm PVG-100 (pepito) boot/recovery partition image.

Monolithic and idempotent: generates the private signing key on first run, reuses
it forever after, then signs. Safe to re-run — an existing key is never
regenerated unless you pass --regen. Re-signing the same input is deterministic
(byte-identical output), so a re-flash never "fixes" anything on its own.


HOW ABOOT VERIFIES THIS (and why a private key is the right call)
----------------------------------------------------------------
pepito's aboot implements Verified Boot 1.0. It reads a DER SEQUENCE appended at
img_size and verifies it: first against the OEM keystore compiled into aboot
(Palm's key -> GREEN); on mismatch, against the public key of the certificate
*embedded in this very signature block* (-> YELLOW); total failure -> RED, which
aboot enforces by powering the device off after 30s.

The `keystore` partition (mmcblk0p33) is all zeros, so we always land on the
self-embedded-cert path. The signing key is NOT pinned to any root of trust at
the bootloader level -- the image authenticates against itself, no CA involved,
and a self-signed cert is as good as any other. Any RSA-2048 key boots yellow;
switching keys cannot cause RED as long as the signature is well-formed. (This
device predates AVB 2.0 entirely: BOARD_AVB_ENABLE is false, there is no vbmeta.)

This historically used the *public* AOSP test key from the Disable_Dm-Verity zip.
Nothing on the device ever trusted that key specifically -- it just happened to
be what shipped. Using it was actively harmful: because its private half is
public, anyone could sign a modified boot image with it and reproduce a
byte-identical yellow screen, including the fingerprint.


⭐ THE KEY IS A HARD PRE-SHIP DECISION (flash-validated 2026-07-16)
------------------------------------------------------------------
aboot passes the boot key digest to the keymaster TA as Root of Trust
(send_boot_key_to_keystore). That ROT is mixed into keymaster's KEY DERIVATION,
not merely stamped into attestation. Confirmed on-device: flashing a boot image
signed with a different key (boot the only variable) produced the
"decryption unsuccessful" / factory-reset prompt -- vold could not unwrap the FBE
keys. Gatekeeper enrollment loss is a downstream symptom of that.

  * COST: changing this key on an existing install FORCES A WIPE. Decide before
    shipping; a dirty flash of a key-switched boot image gets the reset prompt.
  * BENEFIT: it is also a real, TEE-enforced tripwire -- an attacker who reflashes
    a boot image signed with their own key CANNOT decrypt existing user data.
    That is what makes yellow state meaningful here despite the self-signed cert.


HARD CONSTRAINTS ON THE KEY
---------------------------
  * RSA-2048, exactly. The AVBv1 signature block encodes the signature as a
    fixed 256-byte OCTET STRING. A 4096-bit key (e.g. the existing
    vendor/lineage-priv/keys/avb.pem) yields a 512-byte sig and will NOT work.
  * PKCS#8 DER, unencrypted -- aboot never sees the private key.
  * The cert is embedded verbatim in every signed image, so a long DN costs boot
    partition space (the AOSP key's DN costs ~150 bytes extra). Irrelevant in
    practice: ~40 MB of the 64 MB partition is slack.

Key material is PRIVATE and lives in vendor/lineage-priv/keys-boot/, matching the
never-pushed convention of scripts/generate-keys.sh. Never commit the .pk8.
Losing the key is not a brick: it only changes the yellow fingerprint -- delete
it, re-run this script, re-flash.


SIGNATURE STRUCTURE (AVBv1 BootSignature)
    SEQUENCE {
        INTEGER version = 1
        SEQUENCE certificate (DER, verbatim from <name>.x509.pem)
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


Companion: verify-boot-sig.py re-checks any signed image (it reads the embedded
cert, so it needs no key and works on foreign/stock images too).

USAGE  -- run from the android tree root
    # first run: makes the key, then signs
    /usr/bin/python3 scripts/boot-signing/scripts/sign-boot.py
    # recovery
    /usr/bin/python3 scripts/boot-signing/scripts/sign-boot.py \
        flash-staging/recovery_unsigned.img flash-staging/recovery.bin /recovery

Defaults:
    keys:   <tree>/vendor/lineage-priv/keys-boot/boot.{pk8,x509.pem}
    input:  <tree>/flash-staging/boot_unsigned.img
    output: <tree>/flash-staging/boot.bin
    target: /boot          (use /recovery when signing recovery.img)
"""
import argparse
import datetime
import hashlib
import struct
import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509 import load_der_x509_certificate, load_pem_x509_certificate
from cryptography.x509.oid import NameOID

PARTITION_SIZE = 0x4000000   # 64 MB boot partition
ID_OFFSET      = 0x240       # 20-byte mkbootimg SHA1 id
OSVER_OFFSET   = 0x2c        # 4-byte os_version
STOCK_OSVER    = bytes.fromhex('49010410')
KEY_SIZE       = 2048        # see HARD CONSTRAINTS -- do not change

# AlgorithmIdentifier: sha1WithRSAEncryption OID + NULL parameter
ALGO_ID = bytes.fromhex('300d06092a864886f70d0101050500')


def find_tree_root() -> Path:
    """Locate the android tree by walking up from CWD.

    Deliberately NOT derived from __file__: scripts/boot-signing is a symlink
    into the PUBLIC landing repo (~/Projects/lineageos-pepito), so
    Path(__file__).resolve() escapes the tree and would put private key material
    in a public working copy.
    """
    for d in (Path.cwd(), *Path.cwd().parents):
        if (d / 'vendor/lineage-priv').is_dir():
            return d
    sys.exit('ERROR: no vendor/lineage-priv above CWD — run from inside the android tree, '
             'or pass --keys explicitly.')


# ---------------------------------------------------------------- key material

def ensure_key(keys_dir: Path, name: str, cn: str, email: str, days: int, regen: bool):
    """Return (private_key, cert), generating the pair only if absent."""
    pk8_path  = keys_dir / f'{name}.pk8'
    cert_path = keys_dir / f'{name}.x509.pem'

    if regen:
        for p in (pk8_path, cert_path):
            p.unlink(missing_ok=True)

    # Half a pair means a previous run died midway or someone hand-edited the
    # dir. Signing with a mismatched key/cert would embed a cert whose pubkey
    # can't verify the sig -> RED -> a powered-off phone. Refuse instead.
    if pk8_path.exists() != cert_path.exists():
        sys.exit(f'ERROR: {keys_dir} has only one half of the pair. '
                 f'Delete both and re-run (or pass --regen).')

    if pk8_path.exists():
        key  = serialization.load_der_private_key(pk8_path.read_bytes(), password=None)
        cert = load_pem_x509_certificate(cert_path.read_bytes())
        # A cert that doesn't match the key is the same RED footgun as above.
        if cert.public_key().public_numbers() != key.public_key().public_numbers():
            sys.exit(f'ERROR: {cert_path} does not match {pk8_path}. Pass --regen.')
        print(f'key         = {pk8_path} (existing, reused)')
        return key, cert

    keys_dir.mkdir(parents=True, exist_ok=True)
    key = rsa.generate_private_key(public_exponent=65537, key_size=KEY_SIZE)

    attrs = [x509.NameAttribute(NameOID.COUNTRY_NAME, 'US'),
             x509.NameAttribute(NameOID.COMMON_NAME, cn)]
    if email:
        attrs.append(x509.NameAttribute(NameOID.EMAIL_ADDRESS, email))
    subject = x509.Name(attrs)

    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)  # self-signed: nothing checks the issuer, see docstring
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))  # clock-skew slack
        .not_valid_after(now + datetime.timedelta(days=days))
        .sign(key, hashes.SHA256())
    )

    pk8_path.write_bytes(key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ))
    pk8_path.chmod(0o600)
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    print(f'key         = {pk8_path} (NEW — RSA-{KEY_SIZE}, PKCS#8 DER, mode 600)')
    print(f'              back this up; it is private, never commit it')
    return key, cert


def inflate_outer_len(sig_block: bytes) -> bytes:
    """force the outer SEQUENCE to declare 0xFFFF content bytes.

    aboot's verifier rejects any declared length > 0x800 BEFORE parsing or
    RSA, via an exit path that leaves the pre-verify GREEN state untouched
    (see docstring). The inner content is untouched and still fully valid.
    """
    assert sig_block[0] == 0x30 and sig_block[1] == 0x82, 'expected long-form SEQUENCE'
    return b'\x30\x82\xff\xff' + sig_block[4:]


# --------------------------------------------------------------------- signing

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


def der_tlv_len(buf: bytes, off: int) -> int:
    """Total encoded length (header + content) of the DER TLV starting at off."""
    n = buf[off + 1]
    if n < 0x80:
        return 2 + n
    n &= 0x7f
    return 2 + n + int.from_bytes(buf[off + 2:off + 2 + n], 'big')


def self_verify(partition: bytes, img_size: int, target: str) -> str:
    """Re-verify the finished partition the way aboot does.

    Pulls the cert back out of the signature block rather than trusting the key
    we just signed with -- that mirrors aboot's yellow path, so a malformed
    block is caught here instead of costing a flash cycle and a RED power-off.
    """
    sig_block = partition[img_size:]
    assert sig_block[0] == 0x30, f'expected SEQUENCE at img_size, got {hex(sig_block[0])}'

    # Cert is the second element: skip the outer SEQUENCE header and the 3-byte
    # INTEGER version. It must be sliced to its exact DER length -- the parser
    # rejects trailing data, and everything after it is trailing data.
    hdr = 4 if sig_block[1] == 0x82 else 2
    c0 = hdr + 3
    cert = load_der_x509_certificate(sig_block[c0:c0 + der_tlv_len(sig_block, c0)])

    idx = sig_block.find(b'\x04\x82\x01\x00')
    assert idx >= 0, 'RSA OCTET STRING not found in sig block'
    rsa_sig = sig_block[idx + 4:idx + 4 + 256]

    cert.public_key().verify(
        rsa_sig,
        partition[:img_size] + build_auth_attrs(target, img_size),
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
    return cert.fingerprint(hashes.SHA256()).hex(':').upper()


def main():
    ap = argparse.ArgumentParser(
        description='Generate (once) a private boot key and sign a boot image with it.')
    ap.add_argument('--keys', type=Path, default=None,
                    help='keypair dir (default: <tree>/vendor/lineage-priv/keys-boot)')
    ap.add_argument('--name', default='boot', help='basename of the .pk8/.x509.pem pair')
    ap.add_argument('--cn', default='pepito-boot', help='certificate CommonName (new keys only)')
    ap.add_argument('--email', default='kyle@cascade.family')
    ap.add_argument('--days', type=int, default=365 * 30)
    ap.add_argument('--regen', action='store_true',
                    help='discard an existing key and make a new one (changes the fingerprint)')
    ap.add_argument('src',  nargs='?', type=Path, default=None)
    ap.add_argument('dest', nargs='?', type=Path, default=None)
    ap.add_argument('target', nargs='?', default='/boot')
    args = ap.parse_args()

    tree = find_tree_root()
    keys_dir  = args.keys or tree / 'vendor/lineage-priv/keys-boot'
    args.src  = args.src  or tree / 'flash-staging/boot_unsigned.img'
    args.dest = args.dest or tree / 'flash-staging/boot.bin'

    private_key, cert = ensure_key(keys_dir, args.name, args.cn, args.email,
                                   args.days, args.regen)

    # An imported/hand-made key would otherwise trip the 256-byte assert below
    # with a confusing message; the sig block encodes the length as a fixed 0x0100.
    if private_key.key_size != KEY_SIZE:
        sys.exit(f'ERROR: key is RSA-{private_key.key_size}; the signature block '
                 f'requires RSA-{KEY_SIZE}.')

    cert_der = cert.public_bytes(serialization.Encoding.DER)

    img = bytearray(args.src.read_bytes())
    assert img[:8] == b'ANDROID!', 'not an Android boot image'

    img_id = compute_id(bytes(img))
    img[ID_OFFSET:ID_OFFSET + 20] = img_id
    img[OSVER_OFFSET:OSVER_OFFSET + 4] = STOCK_OSVER

    img_size   = compute_img_size(bytes(img))
    auth_attrs = build_auth_attrs(args.target, img_size)

    rsa_sig = private_key.sign(
        bytes(img[:img_size]) + auth_attrs,
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
    assert len(rsa_sig) == 256, f'unexpected RSA sig length: {len(rsa_sig)}'

    version    = b'\x02\x01\x01'
    sig_octet  = b'\x04\x82\x01\x00' + rsa_sig
    sig_block  = seq(version + cert_der + ALGO_ID + auth_attrs + sig_octet)
    sig_block = inflate_outer_len(sig_block)

    sig_len    = len(sig_block)
    padding_sz = PARTITION_SIZE - img_size - sig_len
    assert padding_sz >= 0, f'image ({hex(img_size)}) + sig ({hex(sig_len)}) exceeds partition size'

    partition = bytes(img[:img_size]) + sig_block + b'\x00' * padding_sz
    assert len(partition) == PARTITION_SIZE

    fp = self_verify(partition, img_size, args.target)

    args.dest.write_bytes(partition)
    print(f'subject     = {cert.subject.rfc4514_string()}')
    print(f'expires     = {cert.not_valid_after:%Y-%m-%d}')
    print(f'id          = {img_id.hex()}')
    print(f'os_version  = {STOCK_OSVER.hex()}')
    print(f'img_size    = {hex(img_size)}')
    print(f'sig_len     = {hex(sig_len)}')
    print(f'target      = {args.target}')
    print(f'self-verify = OK (via embedded cert, as aboot does)')
    print(f'fingerprint = {fp}')
    print(f'wrote {args.dest}')
    print()


if __name__ == '__main__':
    main()
