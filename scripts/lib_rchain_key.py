from ecdsa import SigningKey
from ecdsa.curves import SECP256k1
from rchain.crypto import PrivateKey


def generate_key_pair_hex():
    sk = SigningKey.generate(curve=SECP256k1)
    pk = sk.get_verifying_key()
    sk_hex = sk.to_string().hex()
    pk_hex = "04" + pk.to_string().hex()
    return sk_hex, pk_hex


def generate_key_hex():
    return generate_key_pair_hex()[0]

def generate_deployer_data():
    sk = PrivateKey.generate()
    pk = sk.get_public_key()
    rev = pk.get_rev_address()
    eth = pk.get_eth_address()
    return sk.to_hex(), pk.to_hex(), rev, eth


if __name__ == '__main__':
    sk, pk = generate_key_pair_hex()
    print(sk, pk)
