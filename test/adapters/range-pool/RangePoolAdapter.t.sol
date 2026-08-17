// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import {IRangeVault} from 'src/adapters/range-pool/IRangeVault.sol';
import 'src/adapters/range-pool/RangePoolAdapter.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/interfaces/IERC20.sol';

/// @dev The standard Range Router — the ONLY contract exposing `querySwap…`
/// (the single-token router `0x79C1…` has neither). Used purely as the parity oracle.
interface IRangeRouter {
  function querySwapSingleTokenExactIn(
    address pool,
    IERC20 tokenIn,
    IERC20 tokenOut,
    uint256 exactAmountIn,
    address sender,
    bytes calldata userData
  ) external returns (uint256 amountOut);
}

/// @notice Foundry mainnet-fork parity test for `RangePoolAdapter`.
/// @dev Asserts realized output == `Router.querySwapSingleTokenExactIn` to the wei
/// for both live pools, both directions, an amount sweep, plus the native-ETH in/out
/// paths — the same parity oracle as the dex-lib Stage-3 gate.
contract RangePoolAdapterTest is Test {
  using TokenHelper for address;

  RangePoolAdapter adapter;

  address constant VAULT = 0x955244EDC797A1C1b04134b600f819aC23C76081;
  IRangeRouter constant ROUTER = IRangeRouter(0x8726019313CD59D2e33dBE643aaC94A59D5518df);
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  // Live low-TVL pools (see PROGRESS-kyber.md).
  address constant ROME_USDT = 0xAF037E69F0Fa8D1633443Cc0c67D0b73E3694B36; // 2-token 50/50, both 6-dec
  address constant TOP_CRYPTO = 0x67c02FC8F5A4140077999014Efa7fe9d0EE2f29b; // 8-token; WETH idx 6

  address recipient = makeAddr('recipient');

  uint256 constant BLOCK_NUMBER = 25_459_900;

  function setUp() public {
    // ETH_RPC_URL (archive-capable mainnet); falls back to the public KyberSwap RPC.
    string memory rpc = vm.envOr('ETH_RPC_URL', string('https://ethereum-rpc.kyberswap.com'));
    vm.createSelectFork(rpc, BLOCK_NUMBER);
    adapter = new RangePoolAdapter();
  }

  // ---------------------------------------------------------------- helpers

  function _balance(address token, address who) internal view returns (uint256) {
    return token.isNative() ? who.balance : IERC20(token).balanceOf(who);
  }

  /// @dev Read the oracle quote WITHOUT letting its side effects leak.
  /// `querySwapSingleTokenExactIn` reaches Balancer's `quote()`, which returns
  /// normally (no self-revert — it relies on the outer `eth_call` being discarded).
  /// Under a real transaction we spoof off-chain mode via `tx.origin == 0`, but the
  /// pool's virtual-balance writes then PERSIST — so we snapshot around it and revert.
  function _quote(address pool, address tokenIn, address tokenOut, uint256 amountIn)
    internal
    returns (uint256 quoted)
  {
    uint256 snap = vm.snapshotState();
    vm.prank(address(this), address(0)); // off-chain call mode for the query guard
    quoted = ROUTER.querySwapSingleTokenExactIn(
      pool, IERC20(tokenIn), IERC20(tokenOut), amountIn, address(this), ''
    );
    require(vm.revertToState(snap), 'revert failed'); // undo the query's pool-state mutation
  }

  /// @dev Quote the oracle, execute the real adapter swap on the SAME (restored) state,
  /// and assert wei-parity + that `recipient` was credited. State-neutral on return.
  /// `oracleTokenIn/Out` are the WETH-mapped addresses the Vault/Router understand;
  /// `execTokenIn/Out` are what the aggregator passes the adapter (may be native).
  function _assertParity(
    address pool,
    address oracleTokenIn,
    address oracleTokenOut,
    address execTokenIn,
    address execTokenOut,
    uint256 amountIn
  ) internal {
    uint256 quoted = _quote(pool, oracleTokenIn, oracleTokenOut, amountIn);
    assertGt(quoted, 0, 'zero quote');

    uint256 snap = vm.snapshotState();

    uint256 before = _balance(execTokenOut, recipient);
    // Adapter must pass the full output through; measure a delta (its deterministic
    // fork address may hold a pre-existing native balance from mainnet).
    uint256 adapterOutBefore = _balance(execTokenOut, address(adapter));
    bytes memory data = abi.encode(pool);

    uint256 amountUnused;
    uint256 amountOut;
    if (execTokenIn.isNative()) {
      vm.deal(address(this), amountIn);
      (amountUnused, amountOut) = adapter.executeRangePool{value: amountIn}(
        data, amountIn, execTokenIn, execTokenOut, recipient
      );
    } else {
      deal(execTokenIn, address(adapter), amountIn);
      (amountUnused, amountOut) =
        adapter.executeRangePool(data, amountIn, execTokenIn, execTokenOut, recipient);
    }

    assertEq(amountUnused, 0, 'EXACT_IN must consume full input');
    assertEq(amountOut, quoted, 'amountOut != querySwap (wei parity)');
    assertEq(_balance(execTokenOut, recipient) - before, amountOut, 'recipient not credited');
    // adapter must retain none of the output
    assertEq(_balance(execTokenOut, address(adapter)), adapterOutBefore, 'output stuck in adapter');

    require(vm.revertToState(snap), 'revert failed'); // leave state neutral for the next sample
  }

  /// @dev Sweep feasible amounts (skip any the oracle rejects, e.g. below the
  /// MINIMUM_TRADE_AMOUNT gate); require at least `minHits` wei-parity matches.
  function _sweep(
    address pool,
    address oIn,
    address oOut,
    address xIn,
    address xOut,
    uint256[] memory amounts
  ) internal {
    uint256 hits;
    for (uint256 i; i < amounts.length; ++i) {
      // Feasibility probe, isolated from execution state. Snapshot around it because
      // even the try-call's query mutates pool storage persistently in the forge EVM.
      uint256 snap = vm.snapshotState();
      vm.prank(address(this), address(0)); // off-chain call mode for the query guard
      bool feasible;
      try ROUTER.querySwapSingleTokenExactIn(
        pool, IERC20(oIn), IERC20(oOut), amounts[i], address(this), ''
      ) returns (
        uint256 r
      ) {
        feasible = r > 0;
      } catch {
        // infeasible amount (below min-trade / cap) — not counted
      }
      require(vm.revertToState(snap), 'revert failed');

      if (feasible) {
        _assertParity(pool, oIn, oOut, xIn, xOut, amounts[i]);
        ++hits;
      }
    }
    assertGe(hits, 2, 'too few feasible parity samples');
  }

  // ---------------------------------------------------------------- tests

  function test_Parity_ROMEUSDT() public {
    IERC20[] memory t = IRangeVault(VAULT).getPoolTokens(ROME_USDT);
    address rome = address(t[0]);
    address usdt = address(t[1]);

    uint256[] memory amounts = new uint256[](4);
    amounts[0] = 1e6;
    amounts[1] = 1e7;
    amounts[2] = 1e8;
    amounts[3] = 1e9;

    _sweep(ROME_USDT, rome, usdt, rome, usdt, amounts); // ROME -> USDT
    _sweep(ROME_USDT, usdt, rome, usdt, rome, amounts); // USDT -> ROME
  }

  function test_Parity_TopCryptoWETH() public {
    IERC20[] memory t = IRangeVault(VAULT).getPoolTokens(TOP_CRYPTO);
    address weth = address(t[6]);
    address shib = address(t[5]);
    assertEq(weth, WETH, 'WETH not at index 6');

    uint256[] memory wethAmts = new uint256[](4);
    wethAmts[0] = 1e15;
    wethAmts[1] = 1e16;
    wethAmts[2] = 5e16;
    wethAmts[3] = 1e17;

    uint256[] memory shibAmts = new uint256[](4);
    shibAmts[0] = 1e20;
    shibAmts[1] = 1e21;
    shibAmts[2] = 1e22;
    shibAmts[3] = 1e23;

    _sweep(TOP_CRYPTO, weth, shib, weth, shib, wethAmts); // WETH -> SHIB
    _sweep(TOP_CRYPTO, shib, weth, shib, weth, shibAmts); // SHIB -> WETH
  }

  function test_NativeEthIn() public {
    IERC20[] memory t = IRangeVault(VAULT).getPoolTokens(TOP_CRYPTO);
    address shib = address(t[5]);
    // Oracle uses WETH; execution sends native ETH — output must be identical to the wei.
    _assertParity(TOP_CRYPTO, WETH, shib, NATIVE, shib, 5e16);
  }

  function test_NativeEthOut() public {
    IERC20[] memory t = IRangeVault(VAULT).getPoolTokens(TOP_CRYPTO);
    address shib = address(t[5]);
    // SHIB -> native ETH: recipient must receive native, wei-parity vs the WETH quote.
    _assertParity(TOP_CRYPTO, shib, WETH, shib, NATIVE, 1e22);
  }

  function test_OnlyVaultCanCallback() public {
    vm.expectRevert(RangePoolAdapter.OnlyVault.selector);
    adapter.rangePoolUnlockCallback(ROME_USDT, 1e6, address(0), address(0), recipient);
  }

  /// @dev Error symmetry: a sub-MINIMUM_TRADE_AMOUNT swap reverts on-chain, and the
  /// adapter must revert too (it delegates the gate to the Vault, not quote a phantom fill).
  function test_ErrorSymmetry_TooSmall() public {
    IERC20[] memory t = IRangeVault(VAULT).getPoolTokens(TOP_CRYPTO);
    address shib = address(t[5]);
    uint256 dust = 1e6; // 1e6 wei WETH → scaled18 = 1e6 << 1e12 min-trade

    // oracle rejects it (min-trade gate), still in off-chain call mode
    vm.prank(address(this), address(0));
    vm.expectRevert();
    ROUTER.querySwapSingleTokenExactIn(
      TOP_CRYPTO, IERC20(WETH), IERC20(shib), dust, address(this), ''
    );

    // adapter rejects it too
    deal(WETH, address(adapter), dust);
    bytes memory data = abi.encode(TOP_CRYPTO);
    vm.expectRevert();
    adapter.executeRangePool(data, dust, WETH, shib, recipient);
  }
}
