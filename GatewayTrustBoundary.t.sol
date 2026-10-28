// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.17;

import "forge-std/Test.sol";

import {L2WormholeGateway} from "../src/contracts/cross-chain/wormhole/L2WormholeGateway.sol";
import {WormholeBridgeStub} from "../src/contracts/test/WormholeBridgeStub.sol";
import {L2TBTC} from "../src/contracts/cross-chain/wormhole/L2TBTC.sol";
import {TestERC20} from "../src/contracts/test/TestERC20.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/// @title GatewayTrustBoundary
/// @notice Records what the L2 gateway does and does not check about the *origin* of an
///         incoming Wormhole tBTC transfer.
///
///         `L2WormholeGateway.receiveTbtc` measures the balance delta of the wrapped token
///         and credits the receiver encoded in the payload. It never compares
///         `transfer.fromAddress` against `gateways[chainId]`, while the L1 redeemer in the
///         same repository enforces an `allowedSenders` allowlist before accepting a message.
///         This suite documents that asymmetry in executable form.
///
///         It asserts behaviour, not a vulnerability: whether the missing check is a defect
///         depends on whether wrapped tBTC can exist without backing, which is a property of
///         the Wormhole bridge rather than of this contract.
contract GatewayTrustBoundaryTest is Test {
    L2WormholeGateway internal gateway;
    WormholeBridgeStub internal bridgeStub;
    L2TBTC internal l2Tbtc;
    TestERC20 internal wrappedTbtc;

    address internal constant UNREGISTERED = address(0xBEEF);
    address internal constant USER = address(0xA11CE);

    uint256 internal constant AMOUNT = 1e18;

    function setUp() public {
        wrappedTbtc = new TestERC20();
        bridgeStub = new WormholeBridgeStub(wrappedTbtc);
        // TestERC20 минтит только владелец, а минтит его стенд — передаём владение стенду
        wrappedTbtc.transferOwnership(address(bridgeStub));
        l2Tbtc = new L2TBTC();
        l2Tbtc.initialize("L2 tBTC", "L2TBTC");

        gateway = new L2WormholeGateway();
        gateway.initialize(bridgeStub, IERC20Upgradeable(address(wrappedTbtc)), l2Tbtc);
        // L2TBTC.mint доступен только minter'у: назначаем шлюз
        l2Tbtc.addMinter(address(gateway));
    }

    /// @dev Simulates an arriving transfer: the stub mints `amount` wrapped tBTC to the
    ///      gateway, reports `from` as the sender and `receiver` as the payload address.
    function _arrive(address from, address receiver, uint256 amount) internal {
        bridgeStub.setFromAddress(bytes32(uint256(uint160(from))));
        bridgeStub.setReceiverAddress(bytes32(uint256(uint160(receiver))));
        bridgeStub.setTransferAmount(amount);
        gateway.receiveTbtc(hex"00");
    }

    /// @notice Baseline: an arriving transfer mints canonical tBTC to the payload receiver.
    function test_receive_mintsToPayloadReceiver() public {
        _arrive(address(0x1234), USER, AMOUNT);
        assertEq(l2Tbtc.balanceOf(USER), AMOUNT, "canonical tBTC minted to the payload receiver");
    }

    /// @notice The boundary: the sender address is not consulted at all.
    function test_receive_doesNotCheckSenderAgainstGateways() public {
        assertEq(gateway.gateways(uint16(2)), bytes32(0), "gateways[2] empty before the call");

        _arrive(UNREGISTERED, USER, AMOUNT);

        assertEq(
            l2Tbtc.balanceOf(USER),
            AMOUNT,
            "minted for a sender that is not a registered gateway: fromAddress is never compared"
        );
    }

    /// @notice Above the minting limit the wrapped token is forwarded instead of minted.
    function test_receive_respectsMintingLimit() public {
        gateway.updateMintingLimit(AMOUNT / 2);
        _arrive(UNREGISTERED, USER, AMOUNT);

        assertEq(l2Tbtc.balanceOf(USER), 0, "no canonical mint above the limit");
        assertEq(wrappedTbtc.balanceOf(USER), AMOUNT, "wrapped token forwarded instead");
    }

    /// @notice Sending is refused to a chain that has a registered gateway.
    function test_send_refusedWhenGatewayRegistered() public {
        gateway.updateGatewayAddress(uint16(2), bytes32(uint256(1)));
        vm.expectRevert("No Wormhole tBTC gateway on the native chain");
        gateway.sendTbtcWithPayloadToNativeChain(
            AMOUNT, uint16(2), bytes32(uint256(uint160(USER))), 0, hex"00"
        );
    }

    /// @notice The limit is an upper bound, not a post-condition of the forward path.
    function testFuzz_mintedAmountNeverExceedsLimit(uint96 rawAmount) public {
        uint256 amount = uint256(rawAmount) % 1e24;
        vm.assume(amount > 0);
        uint256 limit = 5e17;
        gateway.updateMintingLimit(limit);

        _arrive(UNREGISTERED, USER, amount);

        assertLe(gateway.mintedAmount(), limit, "mintedAmount may never pass the limit");
    }
}
