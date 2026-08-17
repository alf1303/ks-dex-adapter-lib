// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IRangeVault, SwapKind, VaultSwapParams} from './IRangeVault.sol';
import {IWETH} from './IWETH.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/interfaces/IERC20.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @title RangePoolAdapter
/// @notice KyberSwap aggregator executor adapter for Range Pools (Balancer-V3-based
/// custom deployment on Ethereum mainnet). EXACT_IN only.
/// @dev Settlement is Vault-direct: the aggregator transfers `tokenIn` INTO this
/// adapter, then calls `executeRangePool`, which opens the custom Vault's transient
/// accounting context via `unlock`, runs a single `swap`, pays the input with
/// `settle`, and collects the output with `sendTo`. Native ETH is wrapped to WETH on
/// the way in and unwrapped on the way out, since the Vault only knows WETH.
contract RangePoolAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  /// @notice The Range Pool custom Vault (settles swaps via unlock/settle).
  address internal constant VAULT = 0x955244EDC797A1C1b04134b600f819aC23C76081;
  /// @notice Canonical mainnet WETH; the Vault's native-token wrapper.
  address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  /// @notice Thrown when the unlock callback is invoked by anyone other than the Vault.
  error OnlyVault();

  /// @notice Executes a single EXACT_IN Range Pool swap.
  /// @param data ABI-encoded adapter data; word 0 is the pool address.
  /// @param amountIn Exact input amount (already held by this adapter, or sent as
  ///        native ETH `msg.value` when `tokenIn` is native).
  /// @param tokenIn Input token (`TokenHelper.NATIVE_ADDRESS`/zero for native ETH).
  /// @param tokenOut Output token (`TokenHelper.NATIVE_ADDRESS`/zero for native ETH).
  /// @param recipient Receiver of `tokenOut`.
  /// @return amountUnused Always 0 (EXACT_IN consumes the full input).
  /// @return amountOut Output amount delivered to `recipient`.
  function executeRangePool(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address pool = data.decodeAddress(0);

    bytes memory result = IRangeVault(VAULT)
      .unlock(
        abi.encodeCall(this.rangePoolUnlockCallback, (pool, amountIn, tokenIn, tokenOut, recipient))
      );
    amountOut = abi.decode(result, (uint256));
    amountUnused = 0; // EXACT_IN always consumes the full input.
  }

  /// @notice Vault `unlock` callback carrying the actual swap + settlement.
  /// @dev Only callable by the Vault (which invokes it re-entrantly from `unlock`).
  function rangePoolUnlockCallback(
    address pool,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external returns (uint256 amountOut) {
    if (msg.sender != VAULT) revert OnlyVault();

    // The Vault only holds WETH; map native ETH to WETH at both edges.
    bool nativeIn = tokenIn.isNative();
    bool nativeOut = tokenOut.isNative();
    address vaultTokenIn = nativeIn ? WETH : tokenIn;
    address vaultTokenOut = nativeOut ? WETH : tokenOut;

    if (nativeIn) {
      IWETH(WETH).deposit{value: amountIn}();
    }

    (,, amountOut) = IRangeVault(VAULT)
      .swap(
        VaultSwapParams({
          kind: SwapKind.EXACT_IN,
          pool: pool,
          tokenIn: IERC20(vaultTokenIn),
          tokenOut: IERC20(vaultTokenOut),
          amountGivenRaw: amountIn,
          limitRaw: 0, // min-out enforced by the aggregator, not this adapter
          userData: ''
        })
      );

    // Pay the input leg: transfer tokenIn to the Vault and settle the debt.
    vaultTokenIn.safeTransfer(VAULT, amountIn);
    IRangeVault(VAULT).settle(IERC20(vaultTokenIn), amountIn);

    // Collect the output leg.
    if (nativeOut) {
      IRangeVault(VAULT).sendTo(IERC20(WETH), address(this), amountOut);
      IWETH(WETH).withdraw(amountOut);
      recipient.safeTransferNative(amountOut);
    } else {
      IRangeVault(VAULT).sendTo(IERC20(vaultTokenOut), recipient, amountOut);
    }
  }

  /// @dev Receive native ETH from WETH.withdraw during native-out swaps.
  receive() external payable {}
}
