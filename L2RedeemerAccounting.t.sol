// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.17;

import "forge-std/Test.sol";

import {L2BTCRedeemerWormhole} from "../src/contracts/cross-chain/wormhole/L2BTCRedeemerWormhole.sol";
import {L2WormholeGateway} from "../src/contracts/cross-chain/wormhole/L2WormholeGateway.sol";
import {WormholeBridgeStub} from "../src/contracts/test/WormholeBridgeStub.sol";
import {L2TBTC} from "../src/contracts/cross-chain/wormhole/L2TBTC.sol";
import {TestERC20} from "../src/contracts/test/TestERC20.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/// @title L2RedeemerAccounting
/// @notice Accounting invariants of the L2 → L1 redemption path:
///         user → L2BTCRedeemerWormhole → L2WormholeGateway → (Wormhole) → L1.
///
///         Three things worth pinning down, because the contract is upgradeable and the
///         allowance it grants is never explicitly reset:
///           1. after a successful redemption the redeemer holds no tBTC for that user;
///           2. the allowance granted to the gateway does not accumulate across calls;
///           3. dust below the bridging precision is not taken from the user.
contract L2RedeemerAccountingTest is Test {
    L2BTCRedeemerWormhole internal redeemer;
    L2WormholeGateway internal gateway;
    WormholeBridgeStub internal bridgeStub;
    L2TBTC internal tbtc;
    TestERC20 internal wrappedTbtc;

    address internal constant USER = address(0xA11CE);
    bytes32 internal constant L1_REDEEMER = bytes32(uint256(0x1111));

    // P2WPKH, в формате который ждёт BTCUtils.extractHashAt: [длина скрипта][0x00 0x14][20 байт]
    // 0x16 = 22 = длина самого скрипта; первым байтом идёт длина, а не witness-версия.
    bytes internal constant SCRIPT =
        hex"16" hex"0014" hex"1111111111111111111111111111111111111111";

    function setUp() public {
        wrappedTbtc = new TestERC20();
        bridgeStub = new WormholeBridgeStub(wrappedTbtc);
        wrappedTbtc.transferOwnership(address(bridgeStub));

        tbtc = new L2TBTC();
        tbtc.initialize("L2 tBTC", "L2TBTC");

        gateway = new L2WormholeGateway();
        gateway.initialize(bridgeStub, IERC20Upgradeable(address(wrappedTbtc)), tbtc);
        tbtc.addMinter(address(gateway));

        redeemer = new L2BTCRedeemerWormhole();
        redeemer.initialize(address(tbtc), address(gateway), L1_REDEEMER);

        // фондируем пользователя каноническим tBTC через шлюз (как при входящем переводе)
        bridgeStub.setFromAddress(bytes32(uint256(0x1234)));
        bridgeStub.setReceiverAddress(bytes32(uint256(uint160(USER))));
        bridgeStub.setTransferAmount(10e18);
        gateway.receiveTbtc(hex"00");
    }

    function _redeem(uint256 amount) internal returns (uint64) {
        vm.startPrank(USER);
        tbtc.approve(address(redeemer), amount);
        uint64 seq = redeemer.requestRedemption(amount, uint16(2), SCRIPT, 0);
        vm.stopPrank();

        // Настоящий Wormhole-бридж списывает одобренные токены при transferTokensWithPayload;
        // заглушка этого не делает, поэтому имитируем списание от её имени. Без этого шага
        // остаток approve ломает ВТОРОЕ погашение — и это артефакт стенда, а не контракта.
        uint256 left = wrappedTbtc.allowance(address(gateway), address(bridgeStub));
        if (left > 0) {
            vm.prank(address(bridgeStub));
            wrappedTbtc.transferFrom(address(gateway), address(bridgeStub), left);
        }
        return seq;
    }

    /// @notice Invariant 1: the redeemer is a pass-through and keeps no user funds.
    function test_redeem_redeemerHoldsNoTbtc() public {
        _redeem(1e18);
        assertEq(tbtc.balanceOf(address(redeemer)), 0, "redeemer must not retain tBTC");
        assertEq(tbtc.balanceOf(USER), 9e18, "user is debited exactly the normalized amount");
    }

    /// @notice Invariant 2: the gateway consumes the allowance it was given, per call.
    function test_redeem_allowanceDoesNotAccumulate() public {
        _redeem(1e18);
        uint256 afterFirst = tbtc.allowance(address(redeemer), address(gateway));
        _redeem(1e18);
        uint256 afterSecond = tbtc.allowance(address(redeemer), address(gateway));

        assertEq(afterFirst, 0, "allowance fully consumed by the burn on the first call");
        assertEq(afterSecond, 0, "and on the second call");
    }

    /// @notice Invariant 3: dust below 1e10 is not taken from the user.
    ///         `WormholeUtils.normalize` truncates before the transfer, so the user keeps it.
    function test_redeem_dustStaysWithUser() public {
        uint256 amount = 1e18 + 12345; // 12345 wei below the bridging precision
        _redeem(amount);
        assertEq(
            tbtc.balanceOf(USER),
            10e18 - 1e18,
            "user keeps the dust that cannot be bridged"
        );
    }

    /// @notice Below the minimum, the call is refused rather than silently truncated.
    function test_redeem_belowMinimumReverts() public {
        uint256 amount = redeemer.minimumRedemptionAmount() - 1;
        vm.startPrank(USER);
        tbtc.approve(address(redeemer), amount);
        vm.expectRevert(L2BTCRedeemerWormhole.AmountTooLowToRedeem.selector);
        redeemer.requestRedemption(amount, uint16(2), SCRIPT, 0);
        vm.stopPrank();
    }
}
