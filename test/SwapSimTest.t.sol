// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Slot0} from "v4-core/types/Slot0.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Our contracts
import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";
import {SwapSim} from "../src/libraries/SwapSim.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import "forge-std/console.sol";

contract SwapSimTest is Test, Deployers {
    // Use the libraries
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SwapSim for IPoolManager;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    TakeProfitsHook hook;

    PoolId id;

    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // the current liquidity in range
        uint128 liquidity;
    }

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy our hook
        // uint160 flags = uint160(0);
        // address hookAddress = address(flags);
        // deployCodeTo(
        //     "TakeProfitsHook.sol",
        //     abi.encode(manager, ""),
        //     hookAddress
        // );
        hook = TakeProfitsHook(address(0x0));

        // Initialize a pool with these two tokens
        (key, ) = initPool(
            token0,
            token1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        id = key.toId();

        // Add initial liquidity to the pool

        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function test_simple_swap() public {
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(id);
        // console.log("Start Tick : ", tick);
        bool zeroForOne = true;

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        SwapSim.SwapParams memory simParams = SwapSim.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1,
            tickSpacing: key.tickSpacing,
            poolId: id
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        (BalanceDelta result, SwapSim.SwapState memory state) = 
            manager.swapSim(simParams);
        console.log("delta0 : ", result.amount0());
        console.log("delta1 : ", result.amount1());

        // console.log("tickAtCurrentPrice : ", TickMath.getTickAtSqrtPrice(state.sqrtPriceX96));
        // console.log("PriceAtCurrentTick : ", TickMath.getSqrtPriceAtTick(state.tick));

        console.log("Sim Price : ", state.sqrtPriceX96);
        console.log("Sim Tick : ", state.tick);
        console.log("Sim liquidity : ", state.liquidity);

        simParams = SwapSim.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: 2 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
            tickSpacing: key.tickSpacing,
            poolId: id
        });

        SwapSim.StateOverride memory stateOverride = SwapSim.StateOverride ({
            sqrtPriceX96: state.sqrtPriceX96,
            tick: state.tick,
            liquidity: state.liquidity
        });

        (, SwapSim.SwapState memory state2) = 
            manager.swapSim(stateOverride, simParams);

        // Conduct the swap - `afterSwap` should also execute our placed order
        BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        (sqrtPriceX96, tick,,) = manager.getSlot0(id);
        console.log("delta0 : ", delta.amount0());
        console.log("delta1 : ", delta.amount1());
        console.log("End Price : ", sqrtPriceX96);
        console.log("End Tick : ", tick);
        console.log("End Liquidity : ", manager.getLiquidity(id));

        assertEq(state.sqrtPriceX96, sqrtPriceX96, "ERR: price");
        assertEq(state.tick, tick, "ERR: tick");
        assertEq(state.liquidity, manager.getLiquidity(id), "ERR: liquidity");

        // Do another Swap
        params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: 2 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        (sqrtPriceX96, tick,,) = manager.getSlot0(id);

        assertEq(state2.sqrtPriceX96, sqrtPriceX96, "ERR: price 2");
        assertEq(state2.tick, tick, "ERR: tick 2");
        assertEq(state2.liquidity, manager.getLiquidity(id), "ERR: liquidity 2");
    }
}
