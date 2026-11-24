# Morpheus — LayerZero V1 refund bricks claims for stakers that cannot receive ETH

PoC for a bug bounty report to Morpheus (devs@mor.org).

## What it proves

Every Morpheus claim path passes the claim *caller* as the LayerZero V1 refund
address (`DepositPool._claim` -> `Distributor.sendMintMessage` ->
`L1SenderV2.sendMintMessage` -> Endpoint V1 `send()`). SendUln301 refunds
excess `msg.value` via a native transfer that reverts the entire send with
`Transfer_NativeFailed` on failure. The normal frontend flow overpays, so a
staker whose address cannot receive ETH can never claim while overpaying —
rewards stay pending (frozen, not lost; principal unaffected).

Two live victims, proven by claim simulation on a mainnet fork:
`0x8979CdD44b96007753e4BBc429De6f7989DAD16C` (9.3148 MOR, stETH pool 1) and
`0xe2A835CA86dcFEA83c93a6c636192A730C0b5651` (73 wei, stETH pool 0).
Total frozen: 9.3148 MOR + 73 wei, approx $6.32 at $0.678/MOR.

## Run it

Requires [Foundry](https://getfoundry.sh). One command, no setup beyond an
internet connection (the test uses the public `eth.drpc.org` RPC):

```
forge test
```

Expected: 6 tests pass (2 controls, 2 mechanism reverts, the live-victim
brick, and the exact-fee recovery). Fork block: Ethereum 26481079.

If the default RPC endpoint is unavailable from your network, point the test
at any Ethereum archive RPC instead:

```
ETH_RPC_URL=https://ethereum.publicnode.com forge test
```

- `test_refundToEoaSucceeds` / `test_refundToAcceptingWalletSucceeds` —
  controls: claims with a refund-receiving address succeed.
- `test_refundToNoReceiveWalletReverts` /
  `test_refundToRevertingWalletReverts` — mechanism: the refund transfer
  reverts the whole claim when the refund target cannot receive ETH.
- `test_victimClaimBricksOnOverpay` — the live victim's claim reverts
  (9.3148 MOR pending, logged by the test).
- `test_victimClaimSucceedsWithExactFee` — the same claim succeeds at the
  exact 637,339,481,211,881-wei fee, proving the overpay is the trigger.

No privileged accounts are used anywhere; the victim reproduces their own claim.
