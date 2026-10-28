// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

import {Bank} from "../src/contracts/bank/Bank.sol";
import {Bridge} from "../src/contracts/bridge/Bridge.sol";
import {BridgeStub} from "../src/contracts/test/BridgeStub.sol";
import {SystemTestRelay} from "../src/contracts/test/SystemTestRelay.sol";
import {BitcoinTx} from "../src/contracts/bridge/BitcoinTx.sol";
import {Wallets} from "../src/contracts/bridge/Wallets.sol";
import {Redemption} from "../src/contracts/bridge/Redemption.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev Minimal stand-in for the ECDSA wallet registry. `Bridge.initialize` only
///      requires a non-zero address and the Bridge talks to the registry through
///      the `IWalletRegistry` ABI, so a contract exposing the same selectors is
///      enough. Only `seize` / `closeWallet` / `isWalletMember` are ever reached
///      by the code paths under test.
contract MockWalletRegistry {
    struct Seize {
        uint96 amount;
        uint256 rewardMultiplier;
        address notifier;
        bytes32 walletID;
        uint256 membersCount;
    }

    Seize[] public seizes;
    uint256 public closeWalletCalls;

    function seize(
        uint96 amount,
        uint256 rewardMultiplier,
        address notifier,
        bytes32 walletID,
        uint32[] calldata walletMembersIDs
    ) external {
        seizes.push(
            Seize(
                amount,
                rewardMultiplier,
                notifier,
                walletID,
                walletMembersIDs.length
            )
        );
    }

    function seizeCount() external view returns (uint256) {
        return seizes.length;
    }

    function closeWallet(bytes32) external {
        closeWalletCalls++;
    }

    function isWalletMember(
        bytes32,
        uint32[] calldata,
        address,
        uint256
    ) external pure returns (bool) {
        return true;
    }
}

/// @title RedemptionAccounting
/// @notice Accounting of the tBTC v2 Bridge redemption path, exercised against the
///         real `Bridge` implementation (deployed behind a transparent proxy, the
///         way upstream deploys it) with the real `Bank` and the real
///         `Redemption` library.
///
///         Reached:
///           - `Bridge.requestRedemption` (direct path, balanceOwner == redeemer),
///           - `Bank.approveBalanceAndCall` -> `Bridge.receiveBalanceApproval`
///             (split balanceOwner/redeemer path, as used by the vault),
///           - `Bridge.submitRedemptionProof` end-to-end, including the SPV proof,
///             the output processing and the `pendingRedemptionsValue` update,
///           - `Bridge.notifyRedemptionTimeout` (refund + wallet slashing).
///
///         Not reached: wallet creation (`Bridge.__ecdsaWalletCreated`), deposit
///         sweep and moving-funds proofs. Wallets are injected with the
///         `BridgeStub` setters instead, which write exactly the storage the
///         wallet-lifecycle code writes.
contract RedemptionAccountingTest is Test {
    // Re-declared so `vm.expectEmit` can match the Bridge event.
    event RedemptionRequested(
        bytes20 indexed walletPubKeyHash,
        bytes redeemerOutputScript,
        address indexed redeemer,
        uint64 requestedAmount,
        uint64 treasuryFee,
        uint64 txMaxFee
    );

    Bank internal bank;
    SystemTestRelay internal relay;
    MockWalletRegistry internal registry;
    BridgeStub internal bridge;
    BridgeStub internal bridgeImpl;

    address internal constant ADMIN = address(0xAD);
    address internal constant TREASURY = address(0x7BEA5);
    address internal constant VAULT = address(0xBEEF); // balanceOwner
    address internal constant USER = address(0xA11CE); // redeemer
    address internal constant SPV_MAINTAINER = address(0x5B7);

    bytes20 internal constant PKH =
        bytes20(hex"1111111111111111111111111111111111111111");
    bytes20 internal constant PKH2 =
        bytes20(hex"2222222222222222222222222222222222222222");
    bytes20 internal constant PKH3 =
        bytes20(hex"3333333333333333333333333333333333333333");
    bytes32 internal constant ECDSA_ID = keccak256("test-wallet-1");
    bytes32 internal constant ECDSA_ID2 = keccak256("test-wallet-2");

    // Default Bridge parameters set by `initialize`.
    uint64 internal constant DUST = 1_000_000;
    uint64 internal constant DIVISOR = 2000;
    uint64 internal constant TX_MAX_FEE = 100_000;
    uint64 internal constant TX_MAX_TOTAL_FEE = 1_000_000;
    uint32 internal constant TIMEOUT = 5 days;

    uint64 internal constant UTXO_VALUE = 10_000_000;

    BitcoinTx.UTXO internal mainUtxo;

    // ---------------------------------------------------------------------
    // setup
    // ---------------------------------------------------------------------

    function setUp() public {
        bank = new Bank();
        relay = new SystemTestRelay();
        registry = new MockWalletRegistry();

        bridgeImpl = new BridgeStub();
        bridge = BridgeStub(
            address(
                new TransparentUpgradeableProxy(
                    address(bridgeImpl),
                    ADMIN,
                    ""
                )
            )
        );
        bridge.initialize(
            address(bank),
            address(relay),
            TREASURY,
            address(registry),
            payable(address(0x9001)),
            1 // txProofDifficultyFactor
        );
        bank.updateBridge(address(bridge));

        // The test contract deployed the proxy, so it is the Bridge governance.
        assertEq(bridge.governance(), address(this), "harness: governance");
        bridge.setSpvMaintainerStatus(SPV_MAINTAINER, true);

        _fund(VAULT, 100_000_000);
        _fund(USER, 100_000_000);
        _fund(address(this), 100_000_000);
        bank.approveBalance(address(bridge), type(uint256).max);

        mainUtxo = BitcoinTx.UTXO({
            txHash: keccak256("main-utxo-tx"),
            txOutputIndex: 0,
            txOutputValue: UTXO_VALUE
        });

        _installWallet(PKH, ECDSA_ID, mainUtxo);
    }

    /// @dev Mirrors what `Wallets.registerNewWallet` writes on wallet creation.
    function _installWallet(
        bytes20 pkh,
        bytes32 ecdsaWalletID,
        BitcoinTx.UTXO memory utxo
    ) internal {
        bridge.setWallet(
            pkh,
            Wallets.Wallet({
                ecdsaWalletID: ecdsaWalletID,
                mainUtxoHash: keccak256(
                    abi.encodePacked(
                        utxo.txHash,
                        utxo.txOutputIndex,
                        utxo.txOutputValue
                    )
                ),
                pendingRedemptionsValue: 0,
                createdAt: uint32(block.timestamp),
                movingFundsRequestedAt: 0,
                closingStartedAt: 0,
                pendingMovedFundsSweepRequestsCount: 0,
                state: Wallets.WalletState.Live,
                movingFundsTargetWalletsCommitmentHash: bytes32(0)
            })
        );
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(address(bridge));
        bank.increaseBalance(who, amount);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _key(bytes20 pkh, bytes memory script)
        internal
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(keccak256(script), pkh)));
    }

    /// @dev `redeemerOutputScript` is the length-prefixed form: <len><script>.
    function _prefixed(bytes memory bareScript)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(bytes1(uint8(bareScript.length)), bareScript);
    }

    function _data(
        address redeemer,
        bytes20 pkh,
        BitcoinTx.UTXO memory utxo,
        bytes memory script
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                redeemer,
                pkh,
                utxo.txHash,
                utxo.txOutputIndex,
                utxo.txOutputValue,
                script
            );
    }

    /// @dev Split redemption: `owner` pays, `redeemer` is recorded and refunded.
    function _requestAs(
        address owner,
        address redeemer,
        bytes20 pkh,
        BitcoinTx.UTXO memory utxo,
        bytes memory script,
        uint64 amount
    ) internal {
        vm.prank(owner);
        bank.approveBalanceAndCall(
            address(bridge),
            amount,
            _data(redeemer, pkh, utxo, script)
        );
    }

    function _params() internal view returns (uint64, uint64, uint64, uint64) {
        (
            uint64 dust,
            uint64 divisor,
            uint64 txMaxFee,
            uint64 txMaxTotalFee,
            ,
            ,

        ) = bridge.redemptionParameters();
        return (dust, divisor, txMaxFee, txMaxTotalFee);
    }

    function _setRedemptionParameters(
        uint64 dust,
        uint64 divisor,
        uint64 txMaxFee,
        uint64 txMaxTotalFee
    ) internal {
        bridge.updateRedemptionParameters(
            dust,
            divisor,
            txMaxFee,
            txMaxTotalFee,
            TIMEOUT,
            100 * 1e18,
            100
        );
    }

    // ---------------------------------------------------------------------
    // Bitcoin transaction / SPV proof construction
    //
    // The Bridge verifies a real SPV proof before touching the redemption
    // accounting. To reach that accounting we build a syntactically valid
    // Bitcoin transaction and a header chain that satisfies the vendored
    // validator, reporting difficulty 0 through the `SystemTestRelay` stub so
    // that a grindable (minimum-difficulty) header is accepted. This is a
    // harness device only: it proves nothing about Bitcoin consensus, it only
    // opens the gate in front of the code under test.
    // ---------------------------------------------------------------------

    uint256 internal constant TARGET =
        0x7fffff * (2**232); // bits 0x207fffff, difficulty 0

    function _le32(uint32 v) internal pure returns (bytes4) {
        return
            bytes4(
                abi.encodePacked(
                    uint8(v),
                    uint8(v >> 8),
                    uint8(v >> 16),
                    uint8(v >> 24)
                )
            );
    }

    function _le64(uint64 v) internal pure returns (bytes8) {
        return
            bytes8(
                abi.encodePacked(
                    uint8(v),
                    uint8(v >> 8),
                    uint8(v >> 16),
                    uint8(v >> 24),
                    uint8(v >> 32),
                    uint8(v >> 40),
                    uint8(v >> 48),
                    uint8(v >> 56)
                )
            );
    }

    function _inputVector(BitcoinTx.UTXO memory utxo)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                bytes1(0x01), // one input
                utxo.txHash, // outpoint hash, internal (LE) order
                _le32(utxo.txOutputIndex),
                bytes1(0x00), // empty scriptSig
                bytes4(0xffffffff) // sequence
            );
    }

    /// @dev `scripts` are the *bare* output scripts as they appear on chain.
    function _outputVector(uint64[] memory values, bytes[] memory scripts)
        internal
        pure
        returns (bytes memory out)
    {
        out = abi.encodePacked(bytes1(uint8(values.length)));
        for (uint256 i = 0; i < values.length; i++) {
            out = abi.encodePacked(
                out,
                _le64(values[i]),
                bytes1(uint8(scripts[i].length)),
                scripts[i]
            );
        }
    }

    function _txHash(BitcoinTx.Info memory txInfo)
        internal
        pure
        returns (bytes32)
    {
        bytes memory raw = abi.encodePacked(
            txInfo.version,
            txInfo.inputVector,
            txInfo.outputVector,
            txInfo.locktime
        );
        return sha256(abi.encodePacked(sha256(raw)));
    }

    /// @dev Mirrors `BTCUtils.reverseUint256`: interprets the 32 bytes in reverse
    ///      order as a big-endian number.
    function _reverse32(bytes32 h) internal pure returns (uint256 v) {
        for (uint256 i = 0; i < 32; i++) {
            v = (v << 8) | uint8(h[31 - i]);
        }
    }

    /// @dev 80-byte header with `bits = 0x207fffff`, nonce ground until the
    ///      proof-of-work comparison passes against TARGET.
    function _header(bytes32 merkleRoot) internal pure returns (bytes memory) {
        for (uint256 nonce = 0; nonce < 512; nonce++) {
            bytes memory header = abi.encodePacked(
                bytes4(0x01000000), // version
                bytes32(0), // prev block hash (first header, unchecked)
                merkleRoot, // merkle root, LE
                bytes4(0x00000000), // time
                bytes4(0xffff7f20), // bits 0x207fffff, LE
                _le32(uint32(nonce))
            );
            bytes32 digest = sha256(abi.encodePacked(sha256(header)));
            if (_reverse32(digest) <= TARGET) {
                return header;
            }
        }
        revert("harness: header grinding failed");
    }

    /// @dev Two-leaf merkle tree: leaf0 = coinbase hash, leaf1 = tx hash.
    function _spvProof(bytes32 txHash, bytes32 coinbasePreimage)
        internal
        returns (BitcoinTx.Proof memory)
    {
        bytes32 coinbaseHash = sha256(abi.encodePacked(coinbasePreimage));
        bytes32 root = sha256(
            abi.encodePacked(sha256(abi.encodePacked(coinbaseHash, txHash)))
        );

        relay.setCurrentEpochDifficulty(0);
        relay.setPrevEpochDifficulty(0);

        return
            BitcoinTx.Proof({
                merkleProof: abi.encodePacked(coinbaseHash),
                txIndexInBlock: 1,
                bitcoinHeaders: _header(root),
                coinbasePreimage: coinbasePreimage,
                coinbaseProof: abi.encodePacked(txHash)
            });
    }

    function _buildTx(
        BitcoinTx.UTXO memory utxo,
        uint64[] memory values,
        bytes[] memory scripts
    ) internal pure returns (BitcoinTx.Info memory info) {
        info = BitcoinTx.Info({
            version: bytes4(0x01000000),
            inputVector: _inputVector(utxo),
            outputVector: _outputVector(values, scripts),
            locktime: bytes4(0x00000000)
        });
    }

    function _bareP2WPKH(bytes20 pkh) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes2(0x0014), pkh);
    }

    function _scriptPair()
        internal
        pure
        returns (bytes memory bare, bytes memory prefixed)
    {
        bare = abi.encodePacked(bytes2(0x0014), bytes20(hex"f4eedc8f40d4b8e30771f792b065ebec0abaddef"));
        prefixed = _prefixed(bare);
    }

    /// @dev Submits a redemption transaction with `values`/`scripts` outputs.
    function _submitProof(
        BitcoinTx.UTXO memory utxo,
        uint64[] memory values,
        bytes[] memory scripts,
        bytes20 pkh
    ) internal returns (bytes32 txHash) {
        BitcoinTx.Info memory txInfo = _buildTx(utxo, values, scripts);
        txHash = _txHash(txInfo);
        BitcoinTx.Proof memory proof = _spvProof(
            txHash,
            bytes32(uint256(0xC0FFEE))
        );
        vm.prank(SPV_MAINTAINER);
        bridge.submitRedemptionProof(txInfo, proof, utxo, pkh);
    }

    function _submitProofExpectRevert(
        BitcoinTx.UTXO memory utxo,
        uint64[] memory values,
        bytes[] memory scripts,
        bytes20 pkh,
        bytes memory expectedError
    ) internal {
        BitcoinTx.Info memory txInfo = _buildTx(utxo, values, scripts);
        bytes32 txHash = _txHash(txInfo);
        BitcoinTx.Proof memory proof = _spvProof(
            txHash,
            bytes32(uint256(0xC0FFEE))
        );
        vm.expectRevert(expectedError);
        vm.prank(SPV_MAINTAINER);
        bridge.submitRedemptionProof(txInfo, proof, utxo, pkh);
    }

    // =====================================================================
    // 1. requestRedemption with a balanceOwner / redeemer split
    // =====================================================================

    /// @notice The documented fee split and bookkeeping, for a request where the
    ///         payer and the recorded redeemer are different addresses.
    function test_request_splitOwnerAndRedeemer() public {
        (bytes memory bare, bytes memory script) = _scriptPair();
        uint64 amount = DUST; // 1_000_000, exactly at the dust threshold
        uint256 key = _key(PKH, script);

        uint256 ownerBefore = bank.balanceOf(VAULT);
        uint256 redeemerBefore = bank.balanceOf(USER);
        uint256 bridgeBefore = bank.balanceOf(address(bridge));
        uint256 treasuryBefore = bank.balanceOf(TREASURY);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit RedemptionRequested(PKH, script, USER, amount, 500, TX_MAX_FEE);

        _requestAs(VAULT, USER, PKH, mainUtxo, script, amount);

        Redemption.RedemptionRequest memory r = bridge.pendingRedemptions(key);
        assertEq(r.redeemer, USER, "recorded redeemer is the split redeemer");
        assertEq(r.requestedAmount, amount, "requested amount recorded");
        assertEq(r.treasuryFee, amount / DIVISOR, "treasury fee = amount/divisor");
        assertEq(r.treasuryFee, 500, "treasury fee is 500 sat");
        assertEq(r.txMaxFee, TX_MAX_FEE, "tx max fee snapshot");
        assertEq(r.requestedAt, uint32(block.timestamp), "request timestamp");

        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            amount - 500,
            "pendingRedemptionsValue += amount - treasuryFee"
        );
        assertEq(
            bank.balanceOf(VAULT),
            ownerBefore - amount,
            "balance owner is debited the full requested amount"
        );
        assertEq(
            bank.balanceOf(USER),
            redeemerBefore,
            "split redeemer is not debited"
        );
        assertEq(
            bank.balanceOf(address(bridge)),
            bridgeBefore + amount,
            "Bridge holds the full requested amount; the fee is only paid on proof"
        );
        assertEq(
            bank.balanceOf(TREASURY),
            treasuryBefore,
            "treasury is not paid at request time"
        );

        // Independent recomputation of the documented fee formula.
        assertEq(
            uint256(amount) - uint256(r.treasuryFee) - uint256(r.txMaxFee),
            899_500,
            "the redeemer's BTC output will be in [899_500, 999_500]"
        );
    }

    /// @notice The direct path (balanceOwner == redeemer == msg.sender).
    function test_request_directPath() public {
        (, bytes memory script) = _scriptPair();
        uint256 key = _key(PKH, script);
        uint256 before = bank.balanceOf(address(this));

        bridge.requestRedemption(PKH, mainUtxo, script, 2_000_000);

        Redemption.RedemptionRequest memory r = bridge.pendingRedemptions(key);
        assertEq(r.redeemer, address(this), "caller is the redeemer");
        assertEq(r.treasuryFee, 1000, "2_000_000 / 2000");
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            1_999_000,
            "pending value"
        );
        assertEq(
            bank.balanceOf(address(this)),
            before - 2_000_000,
            "caller debited"
        );
    }

    /// @notice `receiveBalanceApproval` decodes the redeemer from calldata; the
    ///         zero address is rejected instead of being recorded.
    function test_request_zeroRedeemerRejected() public {
        (, bytes memory script) = _scriptPair();
        vm.expectRevert("Redeemer must not be the zero address");
        _requestAs(VAULT, address(0), PKH, mainUtxo, script, DUST);
    }

    // =====================================================================
    // 2. key uniqueness and wallet funds
    // =====================================================================

    /// @notice One pending request per (wallet, redeemer output script).
    function test_request_sameKeyRejected() public {
        (, bytes memory script) = _scriptPair();
        _requestAs(VAULT, USER, PKH, mainUtxo, script, DUST);

        uint64 pendingBefore = bridge.wallets(PKH).pendingRedemptionsValue;

        vm.expectRevert(
            "There is a pending redemption request from this wallet to the same address"
        );
        _requestAs(VAULT, USER, PKH, mainUtxo, script, 2 * DUST);

        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            pendingBefore,
            "rejected request leaves no bookkeeping behind"
        );
        assertEq(
            bank.balanceOf(VAULT),
            100_000_000 - DUST,
            "rejected request takes no balance"
        );
    }

    /// @notice The key is (wallet, script), so the same script can be used for a
    ///         different wallet and two different scripts for the same wallet.
    function test_request_keyIncludesWalletAndScript() public {
        (bytes memory bare, bytes memory scriptA) = _scriptPair();
        bytes memory scriptB = _prefixed(
            abi.encodePacked(
                bytes2(0x0014),
                bytes20(hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            )
        );

        _installWallet(PKH2, ECDSA_ID2, mainUtxo);

        _requestAs(VAULT, USER, PKH, mainUtxo, scriptA, DUST);
        _requestAs(VAULT, USER, PKH, mainUtxo, scriptB, DUST); // same wallet, other script
        _requestAs(VAULT, USER, PKH2, mainUtxo, scriptA, DUST); // other wallet, same script

        assertTrue(
            _key(PKH, scriptA) != _key(PKH, scriptB),
            "different scripts, different keys"
        );
        assertTrue(
            _key(PKH, scriptA) != _key(PKH2, scriptA),
            "different wallets, different keys"
        );
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            2 * (DUST - 500),
            "two requests booked against the wallet"
        );
        assertEq(
            bridge.wallets(PKH2).pendingRedemptionsValue,
            DUST - 500,
            "the second wallet has its own bookkeeping"
        );
        assertEq(bare.length, 22, "bare P2WPKH script");
    }

    /// @notice A request that would push the wallet's pending value above its main
    ///         UTXO value is refused, and the refusal is atomic.
    function test_request_insufficientWalletFunds() public {
        (, bytes memory scriptA) = _scriptPair();
        bytes memory scriptB = _prefixed(
            abi.encodePacked(
                bytes2(0x0014),
                bytes20(hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            )
        );

        _requestAs(VAULT, USER, PKH, mainUtxo, scriptA, 6_000_000);
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            5_997_000,
            "first request booked"
        );

        // 5_997_000 + (4_100_000 - 2050) > 10_000_000
        vm.expectRevert("Insufficient wallet funds");
        _requestAs(VAULT, USER, PKH, mainUtxo, scriptB, 4_100_000);

        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            5_997_000,
            "pending value rolled back with the revert"
        );
        assertEq(
            bank.balanceOf(VAULT),
            100_000_000 - 6_000_000,
            "no balance taken for the rejected request"
        );
    }

    /// @notice The boundary is inclusive: pendingRedemptionsValue may fill the
    ///         main UTXO exactly, and the next request is then refused.
    function test_request_pendingMayEqualMainUtxo() public {
        _setRedemptionParameters(DUST, 0, TX_MAX_FEE, TX_MAX_TOTAL_FEE); // divisor 0
        (, bytes memory scriptA) = _scriptPair();
        bytes memory scriptB = _prefixed(
            abi.encodePacked(
                bytes2(0x0014),
                bytes20(hex"cccccccccccccccccccccccccccccccccccccccc")
            )
        );
        bytes memory scriptC = _prefixed(
            abi.encodePacked(
                bytes2(0x0014),
                bytes20(hex"dddddddddddddddddddddddddddddddddddddddd")
            )
        );

        _requestAs(VAULT, USER, PKH, mainUtxo, scriptA, 7_000_000);
        _requestAs(VAULT, USER, PKH, mainUtxo, scriptB, 3_000_000);

        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            UTXO_VALUE,
            "pending value exactly equals the main UTXO value"
        );
        assertEq(
            bridge.pendingRedemptions(_key(PKH, scriptA)).treasuryFee,
            0,
            "divisor 0 gives no treasury fee"
        );

        vm.expectRevert("Insufficient wallet funds");
        _requestAs(VAULT, USER, PKH, mainUtxo, scriptC, DUST);
    }

    // =====================================================================
    // 3. dust threshold and standard output script gate
    // =====================================================================

    function test_request_dustThresholdBoundary() public {
        (, bytes memory scriptA) = _scriptPair();
        bytes memory scriptB = _prefixed(
            abi.encodePacked(
                bytes2(0x0014),
                bytes20(hex"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
            )
        );

        vm.expectRevert("Redemption amount too small");
        _requestAs(VAULT, USER, PKH, mainUtxo, scriptA, DUST - 1);

        _requestAs(VAULT, USER, PKH, mainUtxo, scriptB, DUST);
        assertEq(
            bridge.pendingRedemptions(_key(PKH, scriptB)).requestedAmount,
            DUST,
            "the threshold itself is accepted"
        );
    }

    /// @notice The four standard script types are accepted; the wallet's own
    ///         pubkey hash and non-standard scripts are rejected.
    function test_request_standardScriptGate() public {
        bytes20 pkh = bytes20(
            hex"f4eedc8f40d4b8e30771f792b065ebec0abaddef"
        );

        bytes[4] memory ok = [
            _prefixed(abi.encodePacked(bytes2(0x0014), pkh)), // P2WPKH
            _prefixed(abi.encodePacked(bytes2(0x0020), bytes32(pkh))), // P2WSH
            _prefixed(abi.encodePacked(hex"76a914", pkh, hex"88ac")), // P2PKH
            _prefixed(abi.encodePacked(hex"a914", pkh, hex"87")) // P2SH
        ];
        for (uint256 i = 0; i < ok.length; i++) {
            _requestAs(VAULT, USER, PKH, mainUtxo, ok[i], DUST);
            assertEq(
                bridge.pendingRedemptions(_key(PKH, ok[i])).requestedAmount,
                DUST,
                "standard script accepted"
            );
        }

        // Not length-prefixed: the first byte does not describe the length.
        bytes memory bare = abi.encodePacked(bytes2(0x0014), pkh);
        vm.expectRevert("Redeemer output script must be a standard type");
        _requestAs(VAULT, USER, PKH, mainUtxo, bare, DUST);

        // Length prefix inconsistent with the body.
        bytes memory badPrefix = abi.encodePacked(
            bytes1(0x17),
            bytes2(0x0014),
            pkh
        );
        vm.expectRevert("Redeemer output script must be a standard type");
        _requestAs(VAULT, USER, PKH, mainUtxo, badPrefix, DUST);

        // OP_RETURN.
        bytes memory opReturn = _prefixed(hex"6a0401020304");
        vm.expectRevert("Redeemer output script must be a standard type");
        _requestAs(VAULT, USER, PKH, mainUtxo, opReturn, DUST);

        // P2WPKH paying the wallet's own pubkey hash.
        bytes memory selfWpkh = _prefixed(
            abi.encodePacked(bytes2(0x0014), PKH)
        );
        vm.expectRevert("Redeemer output script must not point to the wallet PKH");
        _requestAs(VAULT, USER, PKH, mainUtxo, selfWpkh, DUST);

        // P2PKH paying the wallet's own pubkey hash.
        bytes memory selfPkh = _prefixed(
            abi.encodePacked(hex"76a914", PKH, hex"88ac")
        );
        vm.expectRevert("Redeemer output script must not point to the wallet PKH");
        _requestAs(VAULT, USER, PKH, mainUtxo, selfPkh, DUST);
    }

    // =====================================================================
    // 3b. wallet-side guards
    // =====================================================================

    function test_request_walletGuards() public {
        (, bytes memory script) = _scriptPair();

        // Unknown wallet: no main UTXO.
        vm.expectRevert("Wallet must be in Live state");
        _requestAs(VAULT, USER, PKH3, mainUtxo, script, DUST);

        // Wrong main UTXO data.
        BitcoinTx.UTXO memory wrong = BitcoinTx.UTXO({
            txHash: keccak256("other"),
            txOutputIndex: 0,
            txOutputValue: UTXO_VALUE
        });
        vm.expectRevert("Invalid main UTXO data");
        _requestAs(VAULT, USER, PKH, wrong, script, DUST);

        // Live wallet without a main UTXO (the wallet redeemed everything).
        bridge.setWallet(
            PKH2,
            Wallets.Wallet({
                ecdsaWalletID: ECDSA_ID2,
                mainUtxoHash: bytes32(0),
                pendingRedemptionsValue: 0,
                createdAt: uint32(block.timestamp),
                movingFundsRequestedAt: 0,
                closingStartedAt: 0,
                pendingMovedFundsSweepRequestsCount: 0,
                state: Wallets.WalletState.Live,
                movingFundsTargetWalletsCommitmentHash: bytes32(0)
            })
        );
        vm.expectRevert("No main UTXO for the given wallet");
        _requestAs(VAULT, USER, PKH2, mainUtxo, script, DUST);

        // Wallet that is moving funds does not accept new requests.
        bridge.setWallet(
            PKH2,
            Wallets.Wallet({
                ecdsaWalletID: ECDSA_ID2,
                mainUtxoHash: keccak256(
                    abi.encodePacked(
                        mainUtxo.txHash,
                        mainUtxo.txOutputIndex,
                        mainUtxo.txOutputValue
                    )
                ),
                pendingRedemptionsValue: 0,
                createdAt: uint32(block.timestamp),
                movingFundsRequestedAt: uint32(block.timestamp),
                closingStartedAt: 0,
                pendingMovedFundsSweepRequestsCount: 0,
                state: Wallets.WalletState.MovingFunds,
                movingFundsTargetWalletsCommitmentHash: bytes32(0)
            })
        );
        vm.expectRevert("Wallet must be in Live state");
        _requestAs(VAULT, USER, PKH2, mainUtxo, script, DUST);
    }

    // =====================================================================
    // 4. fee arithmetic at proof time
    // =====================================================================

    /// @notice End-to-end redemption proof: output processing, bookkeeping release,
    ///         main UTXO replacement by the change output and the Bank movements.
    function test_proof_releasesPendingValueAndSetsChangeAsMainUtxo() public {
        (bytes memory bare, bytes memory script) = _scriptPair();
        uint64 amount = DUST;
        uint256 key = _key(PKH, script);

        _requestAs(VAULT, USER, PKH, mainUtxo, script, amount);

        uint64[] memory values = new uint64[](2);
        bytes[] memory scripts = new bytes[](2);
        values[0] = 899_500; // redeemable (999_500) - txMaxFee (100_000)
        scripts[0] = bare;
        values[1] = 9_100_000; // change
        scripts[1] = _bareP2WPKH(PKH);

        uint256 treasuryBefore = bank.balanceOf(TREASURY);
        bytes32 txHash = _submitProof(mainUtxo, values, scripts, PKH);

        Redemption.RedemptionRequest memory r = bridge.pendingRedemptions(key);
        assertEq(r.requestedAt, 0, "request removed from pendingRedemptions");
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            0,
            "pending value released by the full redeemable amount"
        );
        assertEq(
            bridge.wallets(PKH).mainUtxoHash,
            keccak256(abi.encodePacked(txHash, uint32(1), uint64(9_100_000))),
            "change output became the new main UTXO"
        );
        assertEq(
            bank.balanceOf(TREASURY),
            treasuryBefore + 500,
            "treasury fee paid on proof"
        );
        assertEq(
            bank.balanceOf(address(bridge)),
            0,
            "Bridge burned the redeemable amount and forwarded the fee"
        );
        assertEq(
            bank.balanceOf(VAULT),
            100_000_000 - amount,
            "balance owner is not touched by the proof"
        );
    }

    /// @notice The output value must sit inside [redeemable - txMaxFee, redeemable].
    function test_proof_outputValueRangeEnforced() public {
        (bytes memory bare, bytes memory script) = _scriptPair();
        _requestAs(VAULT, USER, PKH, mainUtxo, script, DUST);

        // 1 satoshi below the minimum acceptable output.
        uint64[] memory low = new uint64[](2);
        bytes[] memory lowScripts = new bytes[](2);
        low[0] = 899_499;
        lowScripts[0] = bare;
        low[1] = 9_100_501;
        lowScripts[1] = _bareP2WPKH(PKH);
        _submitProofExpectRevert(
            mainUtxo,
            low,
            lowScripts,
            PKH,
            "Output value is not within the acceptable range of the pending request"
        );

        // 1 satoshi above the redeemable amount.
        uint64[] memory high = new uint64[](2);
        bytes[] memory highScripts = new bytes[](2);
        high[0] = 999_501;
        highScripts[0] = bare;
        high[1] = 9_000_499;
        highScripts[1] = _bareP2WPKH(PKH);
        _submitProofExpectRevert(
            mainUtxo,
            high,
            highScripts,
            PKH,
            "Output value is not within the acceptable range of the pending request"
        );

        // Both refusals rolled back: the request is still there. The lower
        // boundary value (899_500) is accepted in
        // `test_proof_releasesPendingValueAndSetsChangeAsMainUtxo`.
        assertEq(
            bridge.pendingRedemptions(_key(PKH, script)).requestedAt,
            uint32(block.timestamp),
            "the refused proofs left the request pending"
        );
    }

    /// @notice Only the wallet's own P2PKH/P2WPKH script is treated as change;
    ///         any other unrecognised output reverts the proof.
    function test_proof_unknownOutputIsNotChange() public {
        (bytes memory bare, bytes memory script) = _scriptPair();
        _requestAs(VAULT, USER, PKH, mainUtxo, script, DUST);

        uint64[] memory values = new uint64[](2);
        bytes[] memory scripts = new bytes[](2);
        values[0] = 899_500;
        scripts[0] = bare;
        values[1] = 9_100_000;
        scripts[1] = _bareP2WPKH(
            bytes20(hex"cccccccccccccccccccccccccccccccccccccccc")
        );
        _submitProofExpectRevert(
            mainUtxo,
            values,
            scripts,
            PKH,
            "Output is a non-requested redemption"
        );
    }

    /// @notice The same redemption key cannot be paid twice within one
    ///         transaction: the first output consumes the request, the second one
    ///         finds neither a pending nor a timed-out request.
    function test_proof_duplicateOutputForSameKeyRejected() public {
        (bytes memory bare, bytes memory script) = _scriptPair();
        _requestAs(VAULT, USER, PKH, mainUtxo, script, DUST);

        uint64[] memory values = new uint64[](3);
        bytes[] memory scripts = new bytes[](3);
        values[0] = 899_500;
        scripts[0] = bare;
        values[1] = 899_500;
        scripts[1] = bare; // same script again
        values[2] = UTXO_VALUE - 1_799_000;
        scripts[2] = _bareP2WPKH(PKH);

        _submitProofExpectRevert(
            mainUtxo,
            values,
            scripts,
            PKH,
            "Output is a non-requested redemption"
        );

        assertEq(
            bridge.pendingRedemptions(_key(PKH, script)).requestedAt,
            uint32(block.timestamp),
            "the request survives the refused proof"
        );
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            999_500,
            "bookkeeping untouched"
        );
    }

    /// @notice Candidate issue: the request-time dust check does not imply the
    ///         condition the code comment claims. With `redemptionTxMaxFee` inside
    ///         the governance-legal window `(dust - dust/divisor, dust)` a request
    ///         is accepted but `redeemableAmount - txMaxFee` underflows on proof,
    ///         so the request can never be proven.
    function test_proof_underflowWhenTxMaxFeeExceedsRedeemable() public {
        // Every check in `updateRedemptionParameters` still passes:
        //   dust (1_000_000) > movingFundsDustThreshold (200_000)
        //   dust (1_000_000) > txMaxFee (999_999)
        //   txMaxFee > 0
        //   txMaxTotalFee (1_000_000) >= txMaxFee (999_999)
        _setRedemptionParameters(DUST, DIVISOR, 999_999, 1_000_000);
        (uint64 dust, uint64 divisor, uint64 txMaxFee, ) = _params();
        assertEq(dust, 1_000_000, "dust unchanged");
        assertEq(divisor, DIVISOR, "divisor unchanged");
        assertEq(txMaxFee, 999_999, "tx max fee is one below the dust threshold");

        (, bytes memory script) = _scriptPair();
        _requestAs(VAULT, USER, PKH, mainUtxo, script, DUST); // accepted

        uint256 key = _key(PKH, script);
        Redemption.RedemptionRequest memory r = bridge.pendingRedemptions(key);
        assertEq(r.txMaxFee, 999_999, "request snapshotted the large fee");
        assertEq(r.treasuryFee, 500, "treasury fee");
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            999_500,
            "pending value uses amount - treasuryFee only"
        );

        // redeemableAmount = 999_500, txMaxFee = 999_999 -> 999_500 - 999_999 panics
        // for *every* output value, including the two ends of the nominal range.
        (bytes memory bare, ) = _scriptPair();
        uint64[3] memory outputs = [uint64(0), 1, 999_500];
        for (uint256 i = 0; i < outputs.length; i++) {
            uint64[] memory values = new uint64[](2);
            bytes[] memory scripts = new bytes[](2);
            values[0] = outputs[i];
            scripts[0] = bare;
            values[1] = UTXO_VALUE - outputs[i];
            scripts[1] = _bareP2WPKH(PKH);
            _submitProofExpectRevert(
                mainUtxo,
                values,
                scripts,
                PKH,
                stdError.arithmeticError
            );
        }

        assertEq(
            bridge.pendingRedemptions(key).requestedAt,
            uint32(block.timestamp),
            "no output value can clear the request: it stays pending forever"
        );
    }

    // =====================================================================
    // 4b. timeout: recovery path for an unprovable request
    // =====================================================================

    /// @notice After the redemption timeout the redeemer is refunded the full
    ///         requested amount, the wallet is slashed and moved to MovingFunds,
    ///         and the same (wallet, script) key can never be reused because the
    ///         wallet is no longer Live.
    function test_timeout_refundsAndMovesWalletOutOfLive() public {
        _setRedemptionParameters(DUST, DIVISOR, 999_999, 1_000_000);
        (bytes memory bare, bytes memory script) = _scriptPair();
        _requestAs(VAULT, USER, PKH, mainUtxo, script, DUST);

        uint256 key = _key(PKH, script);
        uint256 userBefore = bank.balanceOf(USER);

        vm.warp(block.timestamp + TIMEOUT + 1);

        uint32[] memory members = new uint32[](1);
        members[0] = 7;
        bridge.notifyRedemptionTimeout(PKH, members, script);

        assertEq(
            bank.balanceOf(USER),
            userBefore + DUST,
            "full requested amount refunded to the recorded redeemer"
        );
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            0,
            "pending value released by amount - treasuryFee"
        );
        assertEq(
            bridge.timedOutRedemptions(key).requestedAt,
            uint32(block.timestamp - TIMEOUT - 1),
            "request moved to timedOutRedemptions with its original timestamp"
        );
        assertEq(
            bridge.pendingRedemptions(key).requestedAt,
            0,
            "request removed from pendingRedemptions"
        );
        assertEq(
            uint8(bridge.wallets(PKH).state),
            uint8(Wallets.WalletState.MovingFunds),
            "wallet left the Live state"
        );
        assertEq(registry.seizeCount(), 1, "wallet operators slashed");
        (
            uint96 slashAmount,
            uint256 rewardMultiplier,
            address notifier,
            bytes32 walletID,

        ) = registry.seizes(0);
        assertEq(slashAmount, 100 * 1e18, "redemptionTimeoutSlashingAmount");
        assertEq(rewardMultiplier, 100, "notifier reward multiplier");
        assertEq(notifier, address(this), "notifier is the caller");
        assertEq(walletID, ECDSA_ID, "slashed the right wallet");

        // The key cannot be reused: the wallet is no longer Live.
        vm.expectRevert("Wallet must be in Live state");
        _requestAs(VAULT, USER, PKH, mainUtxo, script, DUST);
        assertEq(bare.length, 22, "bare script");
    }

    /// @notice A wallet that timed out one request while another is still pending
    ///         cannot even commit to moving its funds: `pendingRedemptionsValue`
    ///         must be zero first.
    function test_timeout_pendingValueBlocksMovingFundsCommitment() public {
        (, bytes memory scriptA) = _scriptPair();
        bytes memory scriptB = _prefixed(
            abi.encodePacked(
                bytes2(0x0014),
                bytes20(hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            )
        );

        _requestAs(VAULT, USER, PKH, mainUtxo, scriptA, 3_000_000);
        _requestAs(VAULT, USER, PKH, mainUtxo, scriptB, 3_000_000);

        vm.warp(block.timestamp + TIMEOUT + 1);
        uint32[] memory members = new uint32[](1);
        members[0] = 7;
        bridge.notifyRedemptionTimeout(PKH, members, scriptA);

        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            3_000_000 - 1500,
            "the second request is still reserved"
        );
        assertEq(
            uint8(bridge.wallets(PKH).state),
            uint8(Wallets.WalletState.MovingFunds),
            "wallet moved to MovingFunds"
        );

        bytes20[] memory targets = new bytes20[](1);
        targets[0] = PKH2;
        vm.expectRevert(
            "Source wallet must handle all pending redemptions first"
        );
        bridge.submitMovingFundsCommitment(
            PKH,
            mainUtxo,
            members,
            1,
            targets
        );
    }

    // =====================================================================
    // 5. invariant: pendingRedemptionsValue never exceeds the main UTXO value
    // =====================================================================

    /// @notice Two pending requests, proven one at a time: the released value and
    ///         the new change output keep the bookkeeping covered at every step.
    function test_proof_sequentialBookkeepingStaysCovered() public {
        (, bytes memory scriptA) = _scriptPair();
        bytes memory scriptB = _prefixed(
            abi.encodePacked(
                bytes2(0x0014),
                bytes20(hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            )
        );
        bytes memory bareB = abi.encodePacked(
            bytes2(0x0014),
            bytes20(hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        );

        _requestAs(VAULT, USER, PKH, mainUtxo, scriptA, 3_000_000);
        _requestAs(VAULT, USER, PKH, mainUtxo, scriptB, 3_000_000);
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            5_997_000,
            "two requests reserved"
        );

        // Prove only A, at the minimum acceptable output value.
        uint64[] memory values = new uint64[](2);
        bytes[] memory scripts = new bytes[](2);
        (bytes memory bareA, ) = _scriptPair();
        values[0] = 2_898_500;
        scripts[0] = bareA;
        values[1] = 7_101_500;
        scripts[1] = _bareP2WPKH(PKH);
        bytes32 txHashA = _submitProof(mainUtxo, values, scripts, PKH);

        uint256 changeA = 7_101_500;
        assertEq(
            bridge.wallets(PKH).mainUtxoHash,
            keccak256(abi.encodePacked(txHashA, uint32(1), uint64(changeA))),
            "main UTXO replaced by the change of the first proof"
        );
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            2_998_500,
            "only the proven request was released"
        );
        assertLe(
            bridge.wallets(PKH).pendingRedemptionsValue,
            changeA,
            "remaining reserve is covered by the new main UTXO"
        );

        // Prove B against the new main UTXO.
        BitcoinTx.UTXO memory utxo2 = BitcoinTx.UTXO({
            txHash: txHashA,
            txOutputIndex: 1,
            txOutputValue: uint64(changeA)
        });
        uint64[] memory values2 = new uint64[](2);
        bytes[] memory scripts2 = new bytes[](2);
        values2[0] = 2_898_500;
        scripts2[0] = bareB;
        values2[1] = 4_203_000;
        scripts2[1] = _bareP2WPKH(PKH);
        bytes32 txHashB = _submitProof(utxo2, values2, scripts2, PKH);

        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            0,
            "all reservations released"
        );
        assertEq(
            bridge.wallets(PKH).mainUtxoHash,
            keccak256(abi.encodePacked(txHashB, uint32(1), uint64(4_203_000))),
            "main UTXO tracks the last change output"
        );
    }

    /// @notice The key is "at most one pending request at a time", not "once ever":
    ///         after the request is processed the same (wallet, script) can be used
    ///         again.
    function test_request_keyReusableAfterProof() public {
        (bytes memory bare, bytes memory script) = _scriptPair();
        _requestAs(VAULT, USER, PKH, mainUtxo, script, DUST);

        uint64[] memory values = new uint64[](2);
        bytes[] memory scripts = new bytes[](2);
        values[0] = 899_500;
        scripts[0] = bare;
        values[1] = 9_100_000;
        scripts[1] = _bareP2WPKH(PKH);

        bytes32 txHash = _submitProof(mainUtxo, values, scripts, PKH);
        assertEq(
            bridge.pendingRedemptions(_key(PKH, script)).requestedAt,
            0,
            "key freed by the proof"
        );

        BitcoinTx.UTXO memory utxo2 = BitcoinTx.UTXO({
            txHash: txHash,
            txOutputIndex: 1,
            txOutputValue: 9_100_000
        });
        _requestAs(VAULT, USER, PKH, utxo2, script, DUST);
        assertEq(
            bridge.pendingRedemptions(_key(PKH, script)).requestedAt,
            uint32(block.timestamp),
            "same key accepted again after the previous request was processed"
        );
    }

    /// @notice Counter-example to the "pending <= UTXO" invariant, reachable only
    ///         through a wallet-authored redemption proof that carries no change
    ///         output: the wallet's main UTXO is deleted while a reserve for
    ///         another request is still outstanding, so that request can only be
    ///         timed out from then on.
    function test_proof_noChangeStrandsRemainingReserve() public {
        // divisor 0 so the numbers are exact and the request amounts equal the
        // reserved amounts.
        _setRedemptionParameters(DUST, 0, TX_MAX_FEE, TX_MAX_TOTAL_FEE);
        (bytes memory bareA, bytes memory scriptA) = _scriptPair();
        bytes memory bareB = abi.encodePacked(
            bytes2(0x0014),
            bytes20(hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        );
        bytes memory scriptB = _prefixed(bareB);

        _requestAs(VAULT, USER, PKH, mainUtxo, scriptA, 9_000_000);
        _requestAs(VAULT, USER, PKH, mainUtxo, scriptB, 1_000_000);
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            UTXO_VALUE,
            "wallet is fully committed"
        );

        // A single output, no change: the 1_000_000 gap is a miner fee, which is
        // exactly at the `redemptionTxMaxTotalFee` limit.
        uint64[] memory values = new uint64[](1);
        bytes[] memory scripts = new bytes[](1);
        values[0] = 9_000_000;
        scripts[0] = bareA;
        _submitProof(mainUtxo, values, scripts, PKH);

        assertEq(
            bridge.wallets(PKH).mainUtxoHash,
            bytes32(0),
            "no change output means no main UTXO"
        );
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            1_000_000,
            "the other request is still reserved"
        );
        assertEq(
            uint8(bridge.wallets(PKH).state),
            uint8(Wallets.WalletState.Live),
            "the wallet is still Live but has no UTXO"
        );

        // The stranded request can no longer be proven...
        uint64[] memory strandedValues = new uint64[](1);
        bytes[] memory strandedScripts = new bytes[](1);
        strandedValues[0] = 1_000_000;
        strandedScripts[0] = bareB;
        _submitProofExpectRevert(
            BitcoinTx.UTXO({
                txHash: keccak256("main-utxo-tx"),
                txOutputIndex: 0,
                txOutputValue: UTXO_VALUE
            }),
            strandedValues,
            strandedScripts,
            PKH,
            "No main UTXO for given wallet"
        );

        // ...and the only way out is the timeout, which refunds the redeemer and
        // ends the wallet.
        vm.warp(block.timestamp + TIMEOUT + 1);
        uint32[] memory members = new uint32[](1);
        members[0] = 7;
        uint256 userBefore = bank.balanceOf(USER);
        bridge.notifyRedemptionTimeout(PKH, members, scriptB);
        assertEq(
            bank.balanceOf(USER),
            userBefore + 1_000_000,
            "redeemer refunded"
        );
        assertEq(
            uint8(bridge.wallets(PKH).state),
            uint8(Wallets.WalletState.Closing),
            "wallet with no main UTXO starts closing on timeout"
        );
        assertEq(registry.seizeCount(), 1, "wallet operators slashed");
    }

    /// @notice Same root cause as the txMaxFee case, reached through the treasury
    ///         fee divisor instead: a divisor of 1 makes the treasury fee equal to
    ///         the whole requested amount, so the redeemable amount is zero.
    function test_proof_zeroRedeemableFromDivisorOneAlsoUnderflows() public {
        _setRedemptionParameters(DUST, 1, TX_MAX_FEE, TX_MAX_TOTAL_FEE);
        (bytes memory bare, bytes memory script) = _scriptPair();

        _requestAs(VAULT, USER, PKH, mainUtxo, script, DUST);

        Redemption.RedemptionRequest memory r = bridge.pendingRedemptions(
            _key(PKH, script)
        );
        assertEq(r.treasuryFee, DUST, "100% treasury fee");
        assertEq(
            bridge.wallets(PKH).pendingRedemptionsValue,
            0,
            "nothing reserved: amount - treasuryFee == 0"
        );

        uint64[] memory values = new uint64[](2);
        bytes[] memory scripts = new bytes[](2);
        values[0] = 0;
        scripts[0] = bare;
        values[1] = 10_000_000;
        scripts[1] = _bareP2WPKH(PKH);
        _submitProofExpectRevert(
            mainUtxo,
            values,
            scripts,
            PKH,
            stdError.arithmeticError
        );
    }

    /// @notice Fuzz: across arbitrary request amounts within the wallet balance,
    ///         the bookkeeping can never exceed the wallet's known UTXO value, and
    ///         a refused request leaves no state behind.
    function testFuzz_pendingNeverExceedsMainUtxo(uint64 a, uint64 b) public {
        uint64 amountA = uint64(bound(a, DUST, 6_000_000));
        uint64 amountB = uint64(bound(b, DUST, 6_000_000));

        bytes memory scriptA = _prefixed(
            abi.encodePacked(
                bytes2(0x0014),
                bytes20(hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            )
        );
        bytes memory scriptB = _prefixed(
            abi.encodePacked(
                bytes2(0x0014),
                bytes20(hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            )
        );

        _requestAs(VAULT, USER, PKH, mainUtxo, scriptA, amountA);
        uint64 pendingAfterA = bridge.wallets(PKH).pendingRedemptionsValue;
        assertEq(pendingAfterA, amountA - amountA / DIVISOR, "first request");
        assertLe(
            pendingAfterA,
            mainUtxo.txOutputValue,
            "invariant after the first request"
        );

        vm.prank(VAULT);
        bank.approveBalance(address(bridge), 0);
        vm.prank(VAULT);
        bank.approveBalance(address(bridge), amountB);
        vm.prank(VAULT);
        try
            bank.approveBalanceAndCall(
                address(bridge),
                amountB,
                _data(USER, PKH, mainUtxo, scriptB)
            )
        {
            uint64 pendingAfterB = bridge.wallets(PKH)
                .pendingRedemptionsValue;
            assertLe(
                pendingAfterB,
                mainUtxo.txOutputValue,
                "invariant after the second request"
            );
            assertEq(
                pendingAfterB,
                (amountA - amountA / DIVISOR) +
                    (amountB - amountB / DIVISOR),
                "bookkeeping is additive"
            );
        } catch {
            assertEq(
                bridge.wallets(PKH).pendingRedemptionsValue,
                pendingAfterA,
                "a refused request changes nothing"
            );
        }
    }
}
