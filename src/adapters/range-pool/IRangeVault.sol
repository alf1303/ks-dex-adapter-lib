// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from 'openzeppelin-contracts/contracts/interfaces/IERC20.sol';

/// @dev Minimal, vendored surface of the Range Pool custom Vault
/// (`0x955244EDC797A1C1b04134b600f819aC23C76081`), a deployment of Balancer V3's
/// `Vault`. Types are copied verbatim from
/// `balancer-v3-monorepo/pkg/interfaces/contracts/vault/{VaultTypes,IVaultMain,IVaultExtension}.sol`
/// so the ABI encoding matches the live contract exactly. Only the members used by
/// the adapter (and its fork test) are declared.

/// @notice Type of swap (Exact In or Exact Out). Order matters: it is ABI-encoded as a uint8.
enum SwapKind {
  EXACT_IN,
  EXACT_OUT
}

/// @notice Data passed into the primary Vault `swap` operation.
struct VaultSwapParams {
  SwapKind kind;
  address pool;
  IERC20 tokenIn;
  IERC20 tokenOut;
  uint256 amountGivenRaw;
  uint256 limitRaw;
  bytes userData;
}

interface IRangeVault {
  /// @notice Opens a transient accounting context; performs a callback on `msg.sender` with `data`.
  function unlock(bytes calldata data) external returns (bytes memory result);

  /// @notice Settles deltas for a token that was transferred into the Vault.
  function settle(IERC20 token, uint256 amountHint) external returns (uint256 credit);

  /// @notice Sends tokens the Vault owes the caller to a recipient.
  function sendTo(IERC20 token, address to, uint256 amount) external;

  /// @notice Swaps tokens based on the provided parameters (raw token decimals).
  function swap(VaultSwapParams memory vaultSwapParams)
    external
    returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw);

  /// @notice Returns the pool's registered tokens, in Vault order. (view; used by the fork test)
  function getPoolTokens(address pool) external view returns (IERC20[] memory tokens);
}
