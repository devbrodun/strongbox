#!/usr/bin/env python3
import secrets
import sys

POLY = 0x11B

def gf_add(a, b):
    return a ^ b

def gf_mul(a, b):
    res = 0
    while b:
        if b & 1:
            res ^= a
        a <<= 1
        if a & 0x100:
            a ^= POLY
        b >>= 1
    return res & 0xFF

def gf_pow(a, n):
    res = 1
    while n:
        if n & 1:
            res = gf_mul(res, a)
        a = gf_mul(a, a)
        n >>= 1
    return res

def gf_inv(a):
    if a == 0:
        raise ZeroDivisionError("no inverse for zero")
    return gf_pow(a, 254)

def eval_poly(coeffs, x):
    y = 0
    power = 1
    for c in coeffs:
        y = gf_add(y, gf_mul(c, power))
        power = gf_mul(power, x)
    return y

def split(k, n, secret_hex):
    secret = bytes.fromhex(secret_hex)
    shares = [[] for _ in range(n)]
    for byte in secret:
        coeffs = [byte] + [secrets.randbelow(256) for _ in range(k - 1)]
        for idx in range(1, n + 1):
            shares[idx - 1].append(eval_poly(coeffs, idx))
    for idx, body in enumerate(shares, start=1):
        print(f"{idx}-{bytes(body).hex()}")

def combine(raw_shares):
    points = []
    for share in raw_shares:
        x_s, y_hex = share.strip().split("-", 1)
        points.append((int(x_s), bytes.fromhex(y_hex)))
    length = len(points[0][1])
    out = bytearray()
    for pos in range(length):
        acc = 0
        for i, (x_i, y_i) in enumerate(points):
            num = 1
            den = 1
            for j, (x_j, _) in enumerate(points):
                if i == j:
                    continue
                num = gf_mul(num, x_j)
                den = gf_mul(den, gf_add(x_i, x_j))
            acc = gf_add(acc, gf_mul(y_i[pos], gf_mul(num, gf_inv(den))))
        out.append(acc)
    print(out.hex())
    for i in range(len(points)):
        points[i] = (0, b"\x00" * length)

def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: shamir.py split K N HEXSECRET | combine SHARE...")
    if sys.argv[1] == "split":
        split(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4])
    elif sys.argv[1] == "combine":
        combine(sys.argv[2:])
    else:
        raise SystemExit("unknown command")

if __name__ == "__main__":
    main()
