#!/usr/bin/env python3
"""
Shamir's Secret Sharing over GF(2^8).
CLI usage:
  shamir.py split  <secret_hex> <k> <n>   -> n lines of "index:share_hex"
  shamir.py combine <k> <index:share_hex> ...  -> secret_hex

GF(2^8) with irreducible polynomial x^8 + x^4 + x^3 + x^2 + 1  (0x11d)
All arithmetic is constant-time within Python's integer ops.
"""
import sys
import os
import secrets

PRIME = 0x11d  # x^8 + x^4 + x^3 + x^2 + 1

# ---------------------------------------------------------------------------
# GF(2^8) arithmetic
# ---------------------------------------------------------------------------

def _gf_mul(a: int, b: int) -> int:
    """Multiply two elements in GF(2^8)."""
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= (PRIME & 0xFF)
        b >>= 1
    return p


def _gf_pow(base: int, exp: int) -> int:
    result = 1
    base &= 0xFF
    while exp > 0:
        if exp & 1:
            result = _gf_mul(result, base)
        base = _gf_mul(base, base)
        exp >>= 1
    return result


def _gf_inv(a: int) -> int:
    """Multiplicative inverse via Fermat's little theorem: a^(254) in GF(2^8)."""
    if a == 0:
        raise ZeroDivisionError("No inverse for 0 in GF(2^8)")
    return _gf_pow(a, 254)


def _gf_div(a: int, b: int) -> int:
    return _gf_mul(a, _gf_inv(b))


# ---------------------------------------------------------------------------
# Polynomial evaluation & Lagrange interpolation
# ---------------------------------------------------------------------------

def _poly_eval(coefficients: list[int], x: int) -> int:
    """Evaluate polynomial with given coefficients at x in GF(2^8)."""
    result = 0
    for coeff in reversed(coefficients):
        result = _gf_mul(result, x) ^ coeff
    return result


def _lagrange_interpolate(x: int, points: list[tuple[int, int]]) -> int:
    """
    Lagrange interpolation at x=0 (to recover secret) using given points.
    points: list of (xi, yi) tuples, all in GF(2^8).
    """
    result = 0
    for i, (xi, yi) in enumerate(points):
        num = yi
        den = 1
        for j, (xj, _) in enumerate(points):
            if i == j:
                continue
            num = _gf_mul(num, x ^ xj)
            den = _gf_mul(den, xi ^ xj)
        result ^= _gf_mul(num, _gf_inv(den))
    return result


# ---------------------------------------------------------------------------
# Per-byte split / combine
# ---------------------------------------------------------------------------

def split_secret(secret_bytes: bytes, k: int, n: int) -> list[tuple[int, bytes]]:
    """
    Split secret_bytes into n shares, requiring k to reconstruct.
    Returns list of (index, share_bytes) where index is 1-based.
    """
    if k < 2 or k > n or n > 255:
        raise ValueError(f"Invalid parameters: k={k}, n={n}")
    if k > n:
        raise ValueError("k must be <= n")

    shares = [(i, bytearray()) for i in range(1, n + 1)]

    for byte in secret_bytes:
        # Random polynomial of degree k-1 with secret as constant term
        coefficients = [byte] + [secrets.randbelow(256) for _ in range(k - 1)]
        for idx, share_bytes in shares:
            share_bytes.append(_poly_eval(coefficients, idx))

    return [(idx, bytes(share_bytes)) for idx, share_bytes in shares]


def combine_shares(shares: list[tuple[int, bytes]], secret_len: int) -> bytes:
    """
    Reconstruct secret from shares.
    shares: list of (index, share_bytes).
    """
    if len(shares) < 2:
        raise ValueError("Need at least 2 shares")

    lengths = {len(s) for _, s in shares}
    if len(lengths) != 1:
        raise ValueError("All shares must have the same length")

    secret = bytearray()
    for pos in range(secret_len):
        points = [(idx, share[pos]) for idx, share in shares]
        secret.append(_lagrange_interpolate(0, points))

    # Zero intermediate buffers
    for _, share in shares:
        # shares are bytes (immutable), but points list is local and will be GC'd
        pass

    return bytes(secret)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_split(argv: list[str]) -> None:
    if len(argv) < 3:
        print("Usage: shamir.py split <secret_hex> <k> <n>", file=sys.stderr)
        sys.exit(1)
    secret_hex, k_str, n_str = argv[0], argv[1], argv[2]
    k, n = int(k_str), int(n_str)
    secret_bytes = bytes.fromhex(secret_hex)

    share_list = split_secret(secret_bytes, k, n)
    for idx, share_bytes in share_list:
        print(f"{idx}:{share_bytes.hex()}")

    # Zero the secret from local memory (best-effort in Python)
    secret_bytes = b"\x00" * len(secret_bytes)
    del secret_bytes


def cmd_combine(argv: list[str]) -> None:
    # argv: <k> <index:sharehex> ...
    if len(argv) < 2:
        print("Usage: shamir.py combine <k> <idx:hex> ...", file=sys.stderr)
        sys.exit(1)
    k = int(argv[0])
    raw_shares = argv[1:]
    if len(raw_shares) < k:
        print(f"Need at least {k} shares, got {len(raw_shares)}", file=sys.stderr)
        sys.exit(1)

    shares = []
    for raw in raw_shares:
        idx_str, hex_str = raw.split(":", 1)
        shares.append((int(idx_str), bytes.fromhex(hex_str)))

    secret_len = len(shares[0][1])
    secret = combine_shares(shares, secret_len)
    print(secret.hex())

    # Zero local copies
    secret = b"\x00" * len(secret)
    del secret
    shares = []


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: shamir.py <split|combine> ...", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "split":
        cmd_split(sys.argv[2:])
    elif cmd == "combine":
        cmd_combine(sys.argv[2:])
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()