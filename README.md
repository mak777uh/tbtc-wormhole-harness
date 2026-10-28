# tBTC v2 — Wormhole redemption harness

A Foundry harness for the tBTC v2 cross-chain redemption path, built to answer one question before
claiming anything about it: **which of the obvious trust assumptions are actually enforced in code?**

The harness compiles the real contracts from `keep-network/tbtc-v2` (`e99676d`, 30 Sep 2026) and runs them
against the project's own Wormhole stub. Eleven tests pass. Two of them record behaviour that is worth
knowing, and the README is explicit about which test proves a defect and which merely documents a design
choice — the distinction matters, because publishing the second as the first is how a researcher loses
credibility.

## What compiles and how

The redeemer contracts do not build out of the box: their `package.json` lists `@keep-network/random-beacon`
and `@keep-network/ecdsa` as `"development"`, and the GitHub repositories are not publicly reachable. They are
on npm, though, and that is enough:

| dependency | source that works |
|---|---|
`@openzeppelin/contracts-upgradeable` 4.8.3 | `git clone --branch v4.8.3` |
`@openzeppelin/contracts` 4.8.3 | `git clone --branch v4.8.3` |
`@keep-network/bitcoin-spv-sol` 3.4.0-solc-0.8 | npm tarball from `registry.npmjs.org` |
`@thesis/solidity-contracts` | `github.com/thesis/solidity-contracts` |
`@keep-network/random-beacon` 2.0.0 | **npm tarball** (the GitHub repo is not public) |
`@keep-network/ecdsa` 2.0.1 | npm tarball |
`@keep-network/sortition-pools` 2.0.0 | npm tarball |

Remappings live in `foundry.toml`. Three details cost an hour each and are worth writing down:

1. `L2TBTC.mint` is `onlyMinter` — the gateway must be added with `addMinter`.
2. `TestERC20.mint` is `onlyOwner` — ownership must be transferred to the stub that mints.
3. `L2TBTC.initialize` takes `(name, symbol)`; no-argument initialisation silently fails to compile.

## What the tests record

### `test/GatewayTrustBoundary.t.sol` — 5 tests

**Documented behaviour, not a vulnerability.** `L2WormholeGateway.receiveTbtc` measures the balance delta of
the wrapped token and credits the receiver named in the payload. It never compares `transfer.fromAddress`
with `gateways[chainId]`. The L1 redeemer in the same repository does the opposite: it refuses any message
whose sender is not in `allowedSenders`.

Whether the asymmetry is a defect depends on whether wrapped tBTC can exist without backing, which is a
property of the Wormhole bridge, not of this contract. On its own this is defense-in-depth — an
`informational` observation, and this repository does not claim otherwise.

It also pins an invariant that does hold: `mintedAmount` never exceeds `mintingLimit`, fuzzed over 256 runs,
and above the limit the wrapped token is forwarded instead of minted.

### `test/L2RedeemerAccounting.t.sol` — 4 tests

The user-fee path, checked as far as it can be without a fork:

- the redeemer is a pass-through and retains no tBTC after a redemption;
- the allowance the redeemer grants the gateway does not accumulate across calls;
- dust below the 1e10 bridging precision is **not** taken from the user (normalisation happens before the
  transfer, so the user keeps it);
- below `minimumRedemptionAmount` the call is refused rather than silently truncated.

### A trap that produced a false positive, recorded so nobody repeats it

The second redemption initially failed with `SafeERC20: approve from non-zero to non-zero allowance`. That
looks like a defect in the gateway, and it is not: the gateway approves the wrapped token to the Wormhole
bridge and relies on `transferTokensWithPayload` to consume it. The project's stub only emits an event and
returns `888` — it never moves the tokens. **The revert was in the harness, not in the contract.** The test
now simulates the pull from the bridge's address before asserting, and the same trap is written into the
operations log of the project this came from.


## Redemption accounting (33 tests in total)

`test/RedemptionAccounting.t.sol` (22 tests) deploys the **real `Bridge`** behind a `TransparentUpgradeableProxy`
with the real `Bank`, a `SystemTestRelay` and a test-only wallet-registry mock, then drives
`submitRedemptionProof` **through the real external entry point**, SPV included, with a structurally valid
fabricated transaction. The report is in [`REDEMPTION_FINDINGS.md`](REDEMPTION_FINDINGS.md).

What survives (asserted with exact numbers): the fee split is exactly `amount / divisor`; `txMaxFee` is
snapshotted per request; `pendingRedemptionsValue` grows by `amount - treasuryFee`; output values are held to
`[redeemable - txMaxFee, redeemable]` (both ±1 sat revert); the `(wallet, script)` key is unique per pending
request and reusable after processing; "Insufficient wallet funds" is inclusive at the exact boundary; dust
and standard-script gates reject what they claim; a timeout refunds the **full** requested amount; and
`pending <= mainUtxo` survives sequential proofs under fuzz.

Three defects were found and **none of them is payable** — all require a trusted role, none escalates
privilege, and the user is refunded on timeout:

1. `updateRedemptionParameters` accepts a `redemptionTxMaxFee` in `(dust - dust/divisor, dust)`, after which
   `redeemableAmount - request.txMaxFee` **panics** in `processNonChangeRedemptionTxOutput`, so the proof can
   never succeed for any output value. The code comment that claims the dust threshold prevents this is
   wrong. Governance-only.
2. The same panic via `redemptionTreasuryFeeDivisor = 1` — no lower bound exists anywhere, including
   `BridgeGovernance`; it also bypasses the wallet-funds guard.
3. A wallet-authored proof with no change output deletes `mainUtxoHash` while `pendingRedemptionsValue > 0`.

That is the honest result: the accounting holds, and the three ways to break it are all reachable only by
roles that are already trusted.

## Also checked, and clean

The three L2 gateways in the Threshold scope carry a backing invariant that holds on live chains with
wei-level precision: Base 45.793774 tBTC, Optimism 6.94643228, Arbitrum 80.0359653 — in each case the
gateway's wrapped-token balance equals `mintedAmount` exactly. Both L2 redeemer proxies hold 0 tBTC and their
proxy admins are contracts.

## Reproduce

```bash
git clone https://github.com/keep-network/tbtc-v2 && cd tbtc-v2/solidity
# copy contracts/ into src/ of a fresh forge project, then fetch the dependencies in the table above
forge test
```

## What this repository does not claim

- It does not claim a vulnerability in tBTC v2. No test here demonstrates loss of funds.
- It does not claim the gateway behaviour is wrong; it claims it is **unchecked**, which is a different
  sentence.
- It does not cover `Bridge.sol`, `Redemption.sol` or `MovingFunds.sol` — the UTXO accounting, where the
  larger surface lives, is not exercised here at all.

## Next

1. Extend to the L1 redeemer (`L1BTCRedeemerWormhole`): the allowlist path, replay of a completed VAA, and
   what happens to a redemption that is requested but never finalized.
2. Fork the L2 gateway at a recent block and check `mintedAmount` against the actual wrapped-token balance —
   an accounting invariant that a unit test cannot see.
3. Only after that, look at the UTXO side.

MIT licensed, as is the code it tests.
