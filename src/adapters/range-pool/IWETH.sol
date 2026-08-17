// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @dev Minimal Wrapped Ether surface used to bridge native ETH <-> WETH at the
/// adapter edges (the Range Vault only deals in WETH).
interface IWETH {
  function deposit() external payable;
  function withdraw(uint256 amount) external;
}
