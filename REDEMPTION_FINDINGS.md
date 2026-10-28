# tBTC v2 Bridge — redemption accounting test harness

Scope: `keep-network/tbtc-v2` @ `e99676d` (30 Sep 2026), as vendored in
`src/contracts/` of this project. Only `test/` was added; `src/contracts/` is
byte-for-byte identical to the upstream tree (verified by SHA-256 comparison of
all 89 `.sol` files against `C:\111\work\threshold\tbtc-v2\solidity\contracts`).

---

## 1. Setup

### What is deployed

`forge test` (solc 0.8.17, optimizer on, 200 runs, project `foundry.toml`
untouched):

| Component | Contract | Notes |
| --- | --- | --- |
| Bridge | `BridgeStub` (`src/contracts/test/BridgeStub.sol`) behind an OpenZeppelin `TransparentUpgradeableProxy` | `Bridge`'s constructor calls `_disableInitializers()`, so — exactly as in production and in the upstream Hardhat tests — the implementation is deployed once and `initialize` runs on the proxy. The test contract deploys the proxy, so it is `governance()` and can call `updateRedemptionParameters`, `setSpvMaintainerStatus`. |
| Bank | real `Bank` | `bank.updateBridge(proxy)`. Balances are created with `vm.prank(bridge); bank.increaseBalance(...)`, i.e. through the same `onlyBridge` entry point a deposit sweep uses. |
| Relay | `SystemTestRelay` | difficulty oracle is set per proof (see "reached / not reached"). |
| ECDSA registry | `MockWalletRegistry` (test file) | only the selectors the Bridge actually calls: `seize`, `closeWallet`, `isWalletMember` (which always returns true). `Bridge.initialize` only requires a non-zero address. |
| Wallets | `BridgeStub.setWallet` / `setWalletMainUtxo` | writes the same storage `Wallets.registerNewWallet` writes (`ecdsaWalletID`, `mainUtxoHash`, `pendingRedemptionsValue`, `createdAt`, `state = Live`). Wallet creation via the real registry/DKG is **not** exercised. |

Baseline parameters are the ones `Bridge.initialize` sets: dust
`1_000_000 sat`, treasury fee divisor `2000` (= 0.05 %, fee = `amount/2000`),
`redemptionTxMaxFee = 100_000 sat`, `redemptionTxMaxTotalFee = 1_000_000 sat`,
timeout `5 days`, slashing `100 T`, notifier reward multiplier `100`.
Wallet main UTXO value `10_000_000 sat`. `redemptionWatchtower` and
`rebateStaking` are `address(0)` in the harness.

### Doubles used

`BridgeStub`, `SystemTestRelay`, `Bank` (real, not a double) and one test-only
`MockWalletRegistry`. `MockTBTCBridge` / `MockTBTCToken` / `MockTBTCVault` /
`TestBTCRedeemer` / `TestBTCUtilsHelper` were **not** used: they exist for the
Vault/L2 test suites and stand in for the very contract whose accounting is
under test here. `WormholeBridgeStub` is irrelevant to the L1 bridge.

### How the SPV gate is opened

`Bridge.submitRedemptionProof` is `onlySpvMaintainer` and verifies a full SPV
proof (`BitcoinTx.validateProof`): vin/vout structure, Merkle inclusion of the
tx **and** of a coinbase, header-chain linkage, per-header proof-of-work and the
accumulated-difficulty comparison against `IRelay`.

The harness builds a syntactically valid Bitcoin transaction (real vin/vout
serialisation, `version|vin|vout|locktime` double-SHA256 txid) and a 1-header
chain whose merkle root commits to `hash256(coinbaseHash ‖ txid)` with the tx at
index 1. The header uses `bits = 0x207fffff`, and its nonce is ground until the
header hash satisfies the PoW comparison; `SystemTestRelay` reports epoch
difficulty `0`, which is what `BTCUtils.calculateDifficulty` returns for that
target. This reproduces the "test/dev relay epoch" path the contract comments
anticipate.

**Consequence, stated plainly:** the SPV mechanism is satisfied by a fabricated
chain and a stub relay. The proof-path tests prove what the Bridge does with a
transaction *once accepted*; they prove nothing about Bitcoin consensus, Merkle
soundness or the difficulty oracle.

### Reachable / not reachable

Reached: `Bridge.requestRedemption`, `Bank.approveBalanceAndCall` →
`Bridge.receiveBalanceApproval` (split balanceOwner/redeemer), the full
`Redemption.requestRedemption` library path, `Bridge.submitRedemptionProof`
(SPV → wallet resolution → outbound-input processing → output processing →
`pendingRedemptionsValue` update → main UTXO replacement → Bank burn / treasury
transfer), `Bridge.notifyRedemptionTimeout` (refund + `seize` + wallet state
transition), `Bridge.submitMovingFundsCommitment` up to its pending-value guard,
`Bridge.updateRedemptionParameters` and `setSpvMaintainerStatus` as governance.

Not reached: wallet creation (`__ecdsaWalletCreated`), deposit reveal/sweep,
moving-funds and moved-funds-sweep proofs, fraud challenges, the redemption
watchtower, `RebateStaking` (address is 0, so `treasuryFee` is never
rebate-adjusted), `TBTCVault` / VendingMachine flows, and the governance
contract's own delay/bounds (`BridgeGovernance.begin*/finalize*`).

---

## 2. Tests written

File: `test/RedemptionAccounting.t.sol` (22 tests, all passing).
Full suite: `forge test` → **33 tests, 33 passed, 0 failed** (22 new +
`GatewayTrustBoundary` 5 + `L2RedeemerAccounting` 4 + `Counter` 2).

| # | Test | Asserts | Result |
| --- | --- | --- | --- |
| 1 | `test_request_splitOwnerAndRedeemer` | With `balanceOwner=VAULT`, `redeemer=USER`, `amount=1_000_000`: event `RedemptionRequested(pkh, script, USER, 1_000_000, 500, 100_000)`; stored record `redeemer/requestedAmount/treasuryFee=500/txMaxFee=100_000/requestedAt`; `pendingRedemptionsValue = 999_500`; VAULT debited 1_000_000, USER untouched, Bridge Bank balance +1_000_000, treasury still 0; `amount - fee - txMaxFee = 899_500` | PASS |
| 2 | `test_request_directPath` | `balanceOwner == redeemer == msg.sender`: fee 1_000, pending 1_999_000 for 2_000_000, caller debited | PASS |
| 3 | `test_request_zeroRedeemerRejected` | `redeemer = 0x0` in `redemptionData` → `"Redeemer must not be the zero address"` | PASS |
| 4 | `test_request_sameKeyRejected` | Second request for the same `(wallet, script)` reverts `"There is a pending redemption request from this wallet to the same address"`, and no balance/bookkeeping change survives | PASS |
| 5 | `test_request_keyIncludesWalletAndScript` | Key = `keccak256(keccak256(script)‖pkh)`: same wallet + other script OK, other wallet + same script OK, three distinct keys | PASS |
| 6 | `test_request_insufficientWalletFunds` | 5_997_000 pending + a 4_100_000 request → `"Insufficient wallet funds"`; pending and Bank balance roll back exactly | PASS |
| 7 | `test_request_pendingMayEqualMainUtxo` | Boundary is inclusive (`>=`): with divisor 0, 7_000_000 + 3_000_000 fills the 10_000_000 UTXO exactly; the next request is refused | PASS |
| 8 | `test_request_dustThresholdBoundary` | `dust - 1` → `"Redemption amount too small"`; `dust` accepted with `requestedAmount == dust` | PASS |
| 9 | `test_request_standardScriptGate` | P2WPKH / P2WSH / P2PKH / P2SH accepted; un-prefixed script, wrong length prefix, OP_RETURN rejected with `"Redeemer output script must be a standard type"`; P2WPKH and P2PKH pointing at the wallet's own PKH rejected with `"Redeemer output script must not point to the wallet PKH"` | PASS |
| 10 | `test_request_walletGuards` | unknown wallet → `"Wallet must be in Live state"`; stale UTXO → `"Invalid main UTXO data"`; Live wallet without UTXO → `"No main UTXO for the given wallet"`; MovingFunds wallet → `"Wallet must be in Live state"` | PASS |
| 11 | `test_proof_releasesPendingValueAndSetsChangeAsMainUtxo` | Full proof: request deleted, `pendingRedemptionsValue 999_500 → 0`, new `mainUtxoHash = keccak(txid‖1‖9_100_000)`, treasury +500, Bridge balance 0 (burned 999_500, forwarded 500), payer untouched | PASS |
| 12 | `test_proof_outputValueRangeEnforced` | Output `899_499` and `999_501` each revert `"Output value is not within the acceptable range of the pending request"` while the request stays pending | PASS |
| 13 | `test_proof_unknownOutputIsNotChange` | A second output not matching the wallet's P2PKH/P2WPKH is treated as a redemption → `"Output is a non-requested redemption"` | PASS |
| 14 | `test_proof_underflowWhenTxMaxFeeExceedsRedeemable` | **Candidate A.** With `txMaxFee = 999_999` (all parameter checks pass), the request is accepted with `treasuryFee=500`, `pending=999_500`, but its proof panics with `Panic(0x11)` for each output value tried (0, 1, 999_500); request stays pending forever | PASS |
| 15 | `test_timeout_refundsAndMovesWalletOutOfLive` | After `timeout+1`: full `requestedAmount` (1_000_000, including the unpaid 500 fee) refunded to the recorded redeemer; `pendingRedemptionsValue → 0`; request moved to `timedOutRedemptions` with its original timestamp; wallet → `MovingFunds`; registry `seize(100e18, 100, notifier, walletID, 1)`; the same key can no longer be requested | PASS |
| 16 | `test_timeout_pendingValueBlocksMovingFundsCommitment` | One of two requests times out → wallet `MovingFunds` with 2_998_500 still reserved → `submitMovingFundsCommitment` reverts `"Source wallet must handle all pending redemptions first"` | PASS |
| 17 | `test_proof_sequentialBookkeepingStaysCovered` | Two requests proven one at a time: after the first proof `pending = 2_998_500 <= change = 7_101_500`; after the second, `pending = 0`; each new main UTXO hash matches its change output | PASS |
| 18 | `test_request_keyReusableAfterProof` | The key is freed by `delete` on proof and the same `(wallet, script)` can be requested again — uniqueness is "one at a time", not "once ever" | PASS |
| 19 | `test_proof_noChangeStrandsRemainingReserve` | **Candidate C.** Proof with no change output (fee exactly `redemptionTxMaxTotalFee`) deletes `mainUtxoHash` while `pendingRedemptionsValue = 1_000_000`; the stranded request can then only revert (`"No main UTXO for given wallet"`) or be timed out (refund + `Closing` + `seize`) | PASS |
| 20 | `test_proof_zeroRedeemableFromDivisorOneAlsoUnderflows` | **Candidate B.** `treasuryFeeDivisor = 1` → fee = whole amount, `pendingRedemptionsValue += 0`, redeemable 0 → same `Panic(0x11)` on proof | PASS |
| 21 | `testFuzz_pendingNeverExceedsMainUtxo(uint64,uint64)` | 256 runs: for any two request amounts in `[dust, 6_000_000]`, `pendingRedemptionsValue <= mainUtxo.txOutputValue` always, exact additive fee arithmetic, and a refused second request changes nothing | PASS |
| 22 | `test_proof_duplicateOutputForSameKeyRejected` | Two outputs paying the same script in one transaction: the first consumes the request, the second reverts `"Output is a non-requested redemption"`; nothing is double-burned | PASS |

---

## 3. What holds

All numbers below were produced by the tests above with the baseline
parameters (dust 1_000_000, divisor 2000, txMaxFee 100_000).

1. **Fee split is exactly as documented.** For `amount = 1_000_000`:
   `treasuryFee = amount / redemptionTreasuryFeeDivisor = 500`,
   `txMaxFee = 100_000` (snapshot of `redemptionTxMaxFee` at request time),
   `pendingRedemptionsValue += amount - treasuryFee = 999_500`, and the
   redeemer's on-chain output must lie in
   `[amount - fee - txMaxFee, amount - fee] = [899_500, 999_500]`.
   `amount - fee` (not `amount`) is what is reserved and later burned; the fee is
   paid to the treasury only on proof, and the miner fee comes out of the change.
2. **The fee is charged to `balanceOwner`, not to `redeemer`.** The split path
   (`Bank.approveBalanceAndCall` → `receiveBalanceApproval`) debits exactly
   `amount` from the payer, records `redeemer` as the refund/reboot address, and
   leaves the payer untouched by the later proof. A zero `redeemer` is refused.
3. **One pending request per `(walletPubKeyHash, redeemerOutputScript)`.** Key =
   `keccak256(keccak256(redeemerOutputScript) ‖ walletPubKeyHash)`, where
   `redeemerOutputScript` is the length-prefixed script (`0x16 0x0014 <20>`).
   The same 20-byte payload under two different length prefixes is impossible
   (`extractHashAt` requires `byte0 + 1 == length`), so the key cannot be
   confused. The key is freed when the request is processed, so the check is
   per-pending-request, not permanent squatting.
4. **The wallet-funds guard is real and atomic.** `pendingRedemptionsValue` may
   equal but never exceed the wallet's main UTXO value at request time
   (`>=` comparison), and a refused request leaves no trace (balance and
   bookkeeping roll back).
5. **`pendingRedemptionsValue <= main UTXO value` survives the redemption proof.**
   Reason, confirmed numerically by test 17: the reserved amount is released by
   `totalBurnableValue = Σ(amount - fee)` while the change is
   `M - Σ outputValue`, and each `outputValue <= amount - fee`, so the new
   change can never be smaller than the remaining reserve. Releasing is by the
   full redeemable amount even when the wallet pays less than that out (the gap
   is the miner fee).
6. **Timeouts are consistent.** `pendingRedemptionsValue` is decreased by
   `requestedAmount - treasuryFee`, the request moves to `timedOutRedemptions`
   with its original `requestedAt`, the redeemer is refunded the *full*
   `requestedAmount` (the fee was never sent to the treasury, so refunding it is
   correct), the operators are slashed `redemptionTimeoutSlashingAmount` with
   `redemptionTimeoutNotifierRewardMultiplier`, and the wallet leaves `Live`
   (`MovingFunds` if it still has a main UTXO, otherwise `Closing`) and never
   returns to `Live` — which is what makes "no `timedOutRedemptions` check in the
   key-uniqueness path" sound.
7. **A wallet with reserved redemptions cannot move its funds.** The commitment
   is refused while `pendingRedemptionsValue != 0`, so a moving-funds proof
   cannot strand a reserved redemption (and no new request is accepted in
   `MovingFunds` state).
8. **Output classification is strict.** The change output must be the wallet's
   P2PKH or P2WPKH script with a non-zero value, and the change must be the only
   such output; any other unrecognised output reverts rather than being silently
   ignored, and a duplicate output for an already-processed key reverts.

---

## 4. Candidate issues

Three candidates, all reproduced by a passing test. **None of them qualifies as
Medium or above under the Immunefi system as I read it, and I say so explicitly
below.** The reason is the same in every case: the trigger is a *trusted role*
(governance, or the wallet signing group), and the user's funds remain
recoverable through `notifyRedemptionTimeout`.

### A. `amount - treasuryFee < txMaxFee` is accepted, and the request can then never be proven (Panic 0x11)

**Code path.** `Redemption.requestRedemption`
(`src/contracts/bridge/Redemption.sol:557-560, 584-586, 613`) checks only
`amount >= redemptionDustThreshold`. `BridgeState.updateRedemptionParameters`
(`BridgeState.sol:528-531`) enforces `_redemptionDustThreshold > _redemptionTxMaxFee`
but says nothing about `txMaxFee` versus `amount - amount/divisor`. The
comment immediately above the fee computation claims:
> "No need to check whether `amount - treasuryFee - txMaxFee > 0` since the
> `redemptionDustThreshold` should force that condition to be always true."

That implication does not hold. At proof time
`Redemption.processNonChangeRedemptionTxOutput` (`Redemption.sol:1030-1038`, and
the identical timed-out branch at `:1067-1074`) evaluates
`redeemableAmount - request.txMaxFee <= outputValue` where
`redeemableAmount = requestedAmount - treasuryFee`; the subtraction is evaluated
before the comparison, so when `redeemableAmount < txMaxFee` every output value
panics with `Panic(0x11)` (arithmetic underflow). The transaction can never be
proven, no matter what the wallet does.

**Reproduction** (`test_proof_underflowWhenTxMaxFeeExceedsRedeemable`).
Governance calls `updateRedemptionParameters(1_000_000, 2000, 999_999, 1_000_000, ...)`
— every check in that function still passes (dust > movingFundsDustThreshold,
dust > txMaxFee, txMaxFee > 0, txMaxTotalFee >= txMaxFee). A redemption of
`1_000_000` (exactly the dust floor) is accepted: `treasuryFee = 500`,
`pendingRedemptionsValue = 999_500`, the payer's 1_000_000 is taken. Trying to
prove that request with output value 0, 1 or 999_500 each reverts with
`Panic(0x11)` inside `submitRedemptionProof`, and the record stays in
`pendingRedemptions` — the panic does not depend on the output value, the
subtraction underflows before the comparison.
The only exit is `notifyRedemptionTimeout` after 5 days, which refunds the
redeemer in full but slashes the wallet operators by 100 T each and forces the
wallet out of `Live`. The unprovable window is
`txMaxFee ∈ (dust - dust/divisor, dust)`, i.e. any value in `[999_501, 999_999]`
makes a request of exactly `amount = dust` unprovable — 499 of the 999_999
admissible values, and a wider amount range for values closer to `dust`.

**Why it might matter.** The parameter validation is the contract's own
statement of what combinations are safe; the comment asserts an invariant that
the validation does not enforce, and violating it silently converts a valid
redemption into an unfulfillable one whose only outcome is a wallet slashing and
a forced wallet migration. Anything integrating the Bridge (vaults, wallets) can
be pushed into an unrecoverable-by-design request by a parameter change alone.

**Severity.** Informational, and **not payable**. Reaching it needs
`onlyGovernance`; Immunefi's tBTC program treats governance and parameter
misconfiguration as out of scope, and there is no attacker profit and no loss of
user funds (the timeout refunds in full). It is a defence-in-depth gap between a
comment/validation pair and the arithmetic, worth fixing by asserting
`_redemptionTxMaxFee <= _redemptionDustThreshold - _redemptionDustThreshold /
_redemptionTreasuryFeeDivisor` (or by checking `amount - treasuryFee >= txMaxFee`
at request time), but it does not meet Medium.

### B. Same defect reached through `redemptionTreasuryFeeDivisor` (100 % fee)

**Code path.** Same two expressions. `updateRedemptionParameters` places **no
lower bound** on `_redemptionTreasuryFeeDivisor`; `requestRedemption` explicitly
tolerates `divisor == 0` (ternary) and does not validate small non-zero values.

**Reproduction** (`test_proof_zeroRedeemableFromDivisorOneAlsoUnderflows`).
`updateRedemptionParameters(1_000_000, 1, 100_000, 1_000_000, ...)` passes every
check. A request of `1_000_000` gets `treasuryFee = 1_000_000`,
`pendingRedemptionsValue += 0`, redeemable amount `0`; the proof panics with
`Panic(0x11)`. Note the second-order effect: because `amount - treasuryFee == 0`,
the wallet-funds guard is bypassed entirely (unlimited requests can be created
against the same UTXO with no reserve), which is only harmless because none of
them can ever be proven.

**Why it matters.** It shows A is a family of cases, not one bad number, and that
the divisor has no economic sanity bound at the Bridge level (the delayed
governance contract in `BridgeGovernance.sol` also applies no bound — it simply
forwards the value to `updateRedemptionParameters`).

**Severity.** Informational, **not payable** — identical reasoning to A, and a
100 % treasury fee is not a configuration anyone would run. Reported only because
it makes the "dust threshold guarantees this" comment demonstrably false for a
second, independent parameter.

### C. A redemption proof with no change output deletes the wallet's main UTXO while a reserve is still outstanding

**Code path.** `Redemption.submitRedemptionProof` (`Redemption.sol:732-749`):
`if (outputsInfo.changeValue > 0) { wallet.mainUtxoHash = ... } else { delete wallet.mainUtxoHash; }`
and only then `wallet.pendingRedemptionsValue -= outputsInfo.totalBurnableValue`.
Nothing requires `pendingRedemptionsValue == 0` when the change output is absent,
and nothing requires the post-state
`pendingRedemptionsValue <= new main UTXO value`. The miner-fee check
(`mainUtxo.txOutputValue - outputsTotalValue <= redemptionTxMaxTotalFee`) is the
only constraint on how much value may be dropped into fees instead of change.

**Reproduction** (`test_proof_noChangeStrandsRemainingReserve`). With
`treasuryFeeDivisor = 0` for exact numbers: wallet UTXO 10_000_000, request A
9_000_000 and request B 1_000_000 to two scripts (`pendingRedemptionsValue =
10_000_000`). The wallet proves A with a single output of 9_000_000 and no change
output; the implied 1_000_000 miner fee is exactly `redemptionTxMaxTotalFee`, so
the proof is accepted. Result: `mainUtxoHash == 0`,
`pendingRedemptionsValue == 1_000_000`, wallet still `Live`. B can never be
proven (`"No main UTXO for given wallet"`, because `resolveRedeemingWallet`
requires a stored main UTXO) and can only be timed out — redeemer refunded,
wallet `Closing`, operators slashed.

**Why it might matter.** It is the one legitimate sequence in which
`pendingRedemptionsValue` ends up larger than the wallet's known UTXO value
(effectively larger than zero), which is exactly the invariant question asked.
The Bridge has no post-condition enforcing it; it relies on the wallet's software
always adding a change output.

**Severity.** Informational, **not payable**. The transaction is authored and
signed by the wallet signing group, which is a bonded, slashed, trusted role; a
user cannot induce this state, no value is stolen, and the affected redeemer is
made whole by the timeout refund. This is self-harm by a trusted party, not an
attack surface. Worth a defensive `require` all the same, because the failure is
silent on-chain and only visible later as a timeout.

### Considered and rejected as findings

* `pendingRedemptionsValue` reserves `amount - treasuryFee` (the maximum payout)
  while the wallet may only have to pay `outputValue >= amount - treasuryFee -
  txMaxFee`. This is conservative over-reservation, not an error: it can only
  *refuse* requests, and the released amount always matches the reserved amount.
* `requestedAt == 0` as the "slot is empty" sentinel: on a chain whose
  `block.timestamp` is 0 a request would be stored with `requestedAt == 0` and a
  second request with the same key would be accepted. Unreachable on any real
  chain; not tested.
* `uint32(block.timestamp)` truncation (year 2106) — pre-existing, documented in
  the struct, informational at best.
* `cancelRebate` matching at most one rebate per timestamp is already documented
  in-code as a known limitation, and `rebateStaking` is not active in this
  harness.

---

## 5. What this does not prove

1. **Nothing about SPV security.** The proofs are fabricated: a stub relay
   reports difficulty 0 and the header chain is a single hand-ground
   minimum-difficulty header. `validateProof`'s merkle/PoW logic is exercised,
   but its soundness is not.
2. **Nothing about mainnet parameter values.** All tests run on the
   `Bridge.initialize` defaults or on values set through
   `updateRedemptionParameters` by the test contract. Whether the deployed
   governance would ever propose candidate A/B/C's values is not modelled, and I
   did not read the mainnet deployment's live parameters.
3. **The governance pipeline is bypassed.** `BridgeGovernance.begin*/finalize*`
   (delays, ownership, event ordering) is not exercised; the parameter change is
   applied directly, as it would be after the delay.
4. **No wallet-creation path.** Wallets are injected through `BridgeStub`
   setters. DKG registration, `liveWalletsCount` bookkeeping by the real
   registry, and anything the ECDSA registry would enforce are stubbed.
5. **No deposit sweep, moving-funds proof, moved-funds sweep, fraud challenge or
   watchtower interaction.** The moving-funds interaction stops at the
   `pendingRedemptionsValue == 0` guard in `submitMovingFundsCommitment`; what
   happens after a commitment is submitted is untested.
6. **No rebate accounting.** `rebateStaking` is `address(0)`, so `treasuryFee`
   is never reduced by `applyForRebate` and the request/timeout/veto rebate
   cancel symmetry is untested. Every fee number here is the un-rebated one.
7. **No vault-level flows.** `TBTCVault`/`VendingMachine` initiating redemptions
   (the real consumer of the split `balanceOwner`/`redeemer` path) is not
   deployed; the split path is driven via `Bank.approveBalanceAndCall` directly,
   which is the same entry point the vault uses.
8. **No P2SH/P2WSH change-output behaviour.** Only P2PKH/P2WPKH change is
   recognised by the Bridge; the (reverting) P2SH-change case was not exercised
   as a test.
9. **No gas, DoS or griefing analysis** of the timeout path (anyone may call
   `notifyRedemptionTimeout`, and each call slashes 100 T per member), and no
   analysis of repeated dust-sized requests as a way to force wallet migrations.
10. **No statement about severity beyond what is written above.** In particular,
    the three candidates are governance- or wallet-triggered; I am not claiming
    any of them is exploitable by an unprivileged attacker.
