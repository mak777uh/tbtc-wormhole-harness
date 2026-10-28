# Dependencies

Everything below is public and needs no account. The GitHub repositories for two of them are not reachable,
so the npm tarballs are the working path.

```bash
# OpenZeppelin 4.8.3 (both packages, same tag)
git clone --depth 1 --branch v4.8.3 https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable.git lib/oz-upgradeable
git clone --depth 1 --branch v4.8.3 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/oz-base

# npm tarballs — the ones whose GitHub repos are not public
curl -L -o btc-spv.tgz https://registry.npmjs.org/@keep-network/bitcoin-spv-sol/-/bitcoin-spv-sol-3.4.0-solc-0.8.tgz
curl -L -o rb.tgz      https://registry.npmjs.org/@keep-network/random-beacon/-/random-beacon-2.0.0.tgz
curl -L -o ecdsa.tgz   https://registry.npmjs.org/@keep-network/ecdsa/-/ecdsa-2.0.1.tgz
curl -L -o sp.tgz      https://registry.npmjs.org/@keep-network/sortition-pools/-/sortition-pools-2.0.0.tgz
for f in btc-spv rb ecdsa sp; do mkdir -p lib/$f && tar -xzf $f.tgz -C lib/$f; done
# note the extra `package/` level: remappings point at lib/<name>/package/

# thesis contracts (permit-enabled ERC20 used by the tests)
git clone --depth 1 https://github.com/thesis/solidity-contracts.git lib/thesis-contracts
```

## Contract source

```bash
git clone --depth 1 https://github.com/keep-network/tbtc-v2.git
cp -r tbtc-v2/solidity/contracts src/contracts
```

Pinned at `e99676d0ee0c2a047bae124579f161e63848f6c7` (30 Sep 2026) when this harness was built.

## Verified

`forge test` → **11 tests passed, 0 failed** on 28 Oct 2026, with forge 1.8.5 and solc 0.8.17.
