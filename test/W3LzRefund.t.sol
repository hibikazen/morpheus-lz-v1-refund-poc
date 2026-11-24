// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IL1SenderV2Refund {
    function sendMintMessage(address user_, uint256 amount_, address refundTo_) external payable;
}

interface IDepositPoolClaim2 {
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function usersData(
        address user_,
        uint256 pool_
    )
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
}

interface ILzEndpointV1Quote {
    function estimateFees(
        uint16 dstChainId,
        address dstAddress,
        bytes calldata payload,
        bool payInZro,
        bytes calldata adapterParams
    ) external view returns (uint256 nativeFee, uint256 zroFee);
}

/// @notice A contract wallet that cannot receive ETH at all (no receive/fallback).
contract NoReceiveWallet {}

/// @notice A contract wallet whose receive() explicitly reverts.
contract RevertingReceiveWallet {
    receive() external payable {
        revert("wallet refuses ETH");
    }
}

/// @notice A contract wallet that accepts ETH (control: behaves like a Safe).
contract AcceptingWallet {
    receive() external payable {}
}

/**
 * @notice W3 CONFIRMED FINDING (Low): LayerZero V1 refund bricks claims for
 * stakers that cannot receive ETH.
 *
 * Claim path: DepositPool.claim/claimFor/claimReferrerTier -> Distributor.sendMintMessage
 * -> L1SenderV2.sendMintMessage -> LZ Endpoint V1 send() with refundTo = the claim CALLER
 * (DepositPool._claim passes _msgSender() as refundTo_; claimFor passes its caller).
 *
 * SendUln301 (the default V1 send library) refunds excess msg.value to refundTo via a
 * native transfer that REVERTS the entire send on failure with
 * Transfer_NativeFailed(address,uint256) (0x465bc834). Normal frontend flow overpays
 * (0.0005-0.002 ETH vs ~0.00005 ETH fee), so the refund almost always triggers.
 * A staker whose address cannot receive ETH therefore cannot claim via the normal flow.
 *
 * Recovery exists (exact-fee claim, or claimFor by an authorized EOA), so this is a
 * temporary freeze, not a permanent lock — Low, not Medium/High.
 *
 * Live victim (quantified): 0x8979CdD44b96007753e4BBc429De6f7989DAD16C, an EIP-7702
 * account whose delegate 0x0727ca41efc85f75cef26ee48f825893b4836786 rejects ETH,
 * holds 9,314,780,758,112,993,497 wei = 9.3148 MOR (~$6.32 at $0.678/MOR) of stored
 * pending rewards in stETH DepositPool private pool 1, and cannot claim them while
 * overpaying. Of 190 enumerated stakers, 40 are contracts/7702 accounts; 39 accept
 * ETH (the 19 contracts are Gnosis Safe proxies); this is the only affected one.
 *
 * Fork: Ethereum @ block 26481079.
 */
contract W3LzRefundTest is Test {
    error Transfer_NativeFailed(address to, uint256 amount);

    address constant L1_SENDER_V2 = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant LZ_ENDPOINT_V1 = 0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675;
    address constant L2_MESSAGE_RECEIVER = 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant VICTIM = 0x8979CdD44b96007753e4BBc429De6f7989DAD16C;

    // L1SenderV2 adapterParams: type-1, 250,000 gas (the MOR-KI-008 fix, live on-chain).
    bytes constant ADAPTER_PARAMS =
        hex"0001000000000000000000000000000000000000000000000000000000000003d090";

    address user = makeAddr("user");
    NoReceiveWallet noReceive;
    RevertingReceiveWallet revertingReceive;
    AcceptingWallet accepting;

    function setUp() public {
        // RPC override: set ETH_RPC_URL to any Ethereum archive RPC if the
        // default endpoint is unavailable from your network.
        string memory rpc = vm.envOr(
            "ETH_RPC_URL",
            string("https://ethereum.publicnode.com")
        );
        vm.createSelectFork(rpc, 26481079);
        noReceive = new NoReceiveWallet();
        revertingReceive = new RevertingReceiveWallet();
        accepting = new AcceptingWallet();
        vm.deal(DISTRIBUTOR, 10 ether);
        vm.deal(VICTIM, 10 ether);
    }

    function _sendMint(address refundTo) internal {
        vm.prank(DISTRIBUTOR);
        IL1SenderV2Refund(L1_SENDER_V2).sendMintMessage{value: 0.01 ether}(user, 1 ether, refundTo);
    }

    /// Quotes the LZ V1 fee for the mint payload (fee depends on payload length,
    /// 64 bytes, not on the amount value) so the expected refund is exact.
    function _quoteFee(address user_, uint256 amount_) internal view returns (uint256) {
        (uint256 nativeFee, ) = ILzEndpointV1Quote(LZ_ENDPOINT_V1).estimateFees(
            110,
            L2_MESSAGE_RECEIVER,
            abi.encode(user_, amount_),
            false,
            ADAPTER_PARAMS
        );
        return nativeFee;
    }

    /// Control: EOA refund target — send succeeds, excess refunded to the EOA.
    /// NOTE: label chosen to avoid makeAddr("eoa"), which collides with a real
    /// EIP-7702-delegated account on mainnet (0x060DfB66...).
    function test_refundToEoaSucceeds() public {
        address eoa = makeAddr("eoaRefundTarget");
        uint256 before = eoa.balance;
        _sendMint(eoa);
        assertGt(eoa.balance, before, "EOA must receive the excess refund");
    }

    /// Control: accepting contract wallet — send succeeds.
    function test_refundToAcceptingWalletSucceeds() public {
        _sendMint(address(accepting));
        assertGt(address(accepting).balance, 0, "accepting wallet must receive the refund");
    }

    /// The finding, mechanism level: a refund to a non-payable contract wallet
    /// reverts the WHOLE send with Transfer_NativeFailed — the claim bricks.
    function test_refundToNoReceiveWalletReverts() public {
        uint256 refund = 0.01 ether - _quoteFee(user, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(Transfer_NativeFailed.selector, address(noReceive), refund)
        );
        _sendMint(address(noReceive));
    }

    /// Same with an explicitly reverting receive().
    function test_refundToRevertingWalletReverts() public {
        uint256 refund = 0.01 ether - _quoteFee(user, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                Transfer_NativeFailed.selector,
                address(revertingReceive),
                refund
            )
        );
        _sendMint(address(revertingReceive));
    }

    /// End-to-end, live victim: the affected 7702 staker's real claim from stETH
    /// private pool 1 (9.3148 MOR stored pending) reverts with Transfer_NativeFailed
    /// when the claim overpays the LZ fee (the normal case).
    function test_victimClaimBricksOnOverpay() public {
        (, , , uint256 storedPending, , , , , ) = IDepositPoolClaim2(STETH_POOL).usersData(
            VICTIM,
            1
        );
        assertGt(storedPending, 0, "victim must have pending rewards in pool 1");
        emit log_named_uint("victim stored pending MOR (wei)", storedPending);

        uint256 refund = 0.01 ether - _quoteFee(VICTIM, storedPending);
        vm.prank(VICTIM);
        vm.expectRevert(
            abi.encodeWithSelector(Transfer_NativeFailed.selector, VICTIM, refund)
        );
        IDepositPoolClaim2(STETH_POOL).claim{value: 0.01 ether}(1, VICTIM);
    }

    /// Recovery path (why this is Low, not High): the SAME claim succeeds when
    /// sent with the exact LZ fee — no refund is due, so nothing reverts.
    /// Exact fee is quoted from the endpoint in the same block.
    function test_victimClaimSucceedsWithExactFee() public {
        (, , , uint256 storedPending, , , , , ) = IDepositPoolClaim2(STETH_POOL).usersData(
            VICTIM,
            1
        );
        assertGt(storedPending, 0, "victim must have pending rewards in pool 1");

        bytes memory payload = abi.encode(VICTIM, storedPending);
        (uint256 nativeFee, ) = ILzEndpointV1Quote(LZ_ENDPOINT_V1).estimateFees(
            110,
            L2_MESSAGE_RECEIVER,
            payload,
            false,
            ADAPTER_PARAMS
        );
        assertGt(nativeFee, 0, "fee quote must be positive");
        emit log_named_uint("exact LZ fee (wei)", nativeFee);

        vm.prank(VICTIM);
        IDepositPoolClaim2(STETH_POOL).claim{value: nativeFee}(1, VICTIM);

        (, , , uint256 pendingAfter, , , , , ) = IDepositPoolClaim2(STETH_POOL).usersData(
            VICTIM,
            1
        );
        assertEq(pendingAfter, 0, "claim must have consumed the pending rewards");
    }
}
