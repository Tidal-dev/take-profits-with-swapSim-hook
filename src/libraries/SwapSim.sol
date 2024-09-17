// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Slot0} from "v4-core/types/Slot0.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {LiquidityMath} from "v4-core/libraries/LiquidityMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {TickBitmapSim} from "./TickBitmapSim.sol";

import "forge-std/console.sol";

/// @notice a library with all actions that can be performed on a pool
library SwapSim {

    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Pool for State;
    using ProtocolFeeLibrary for *;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;
    using StateLibrary for IPoolManager;
    using TickBitmapSim for IPoolManager;

    /// @notice Thrown when tickLower is not below tickUpper
    /// @param tickLower The invalid tickLower
    /// @param tickUpper The invalid tickUpper
    error TicksMisordered(int24 tickLower, int24 tickUpper);

    /// @notice Thrown when tickLower is less than min tick
    /// @param tickLower The invalid tickLower
    error TickLowerOutOfBounds(int24 tickLower);

    /// @notice Thrown when tickUpper exceeds max tick
    /// @param tickUpper The invalid tickUpper
    error TickUpperOutOfBounds(int24 tickUpper);

    /// @notice For the tick spacing, the tick has too much liquidity
    error TickLiquidityOverflow(int24 tick);

    /// @notice Thrown when trying to initialize an already initialized pool
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @notice Thrown when sqrtPriceLimitX96 on a swap has already exceeded its limit
    /// @param sqrtPriceCurrentX96 The invalid, already surpassed sqrtPriceLimitX96
    /// @param sqrtPriceLimitX96 The surpassed price limit
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);

    /// @notice Thrown when sqrtPriceLimitX96 lies outside of valid tick/price range
    /// @param sqrtPriceLimitX96 The invalid, out-of-bounds sqrtPriceLimitX96
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    /// @notice Thrown by donate if there is currently 0 liquidity, since the fees will not go to any liquidity providers
    error NoLiquidityToReceiveFees();

    /// @notice Thrown when trying to swap with max lp fee and specifying an output amount
    error InvalidFeeForExactOut();

    // info stored for each initialized individual tick
    struct TickInfo {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    /// @dev The state of a pool
    struct State {
        Slot0 slot0;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint128 liquidity;
        mapping(int24 => TickInfo) ticks;
        mapping(int16 => uint256) tickBitmap;
        mapping(bytes32 => Position.Info) positions;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
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

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    struct SwapParams {
        int24 tickSpacing;
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
        int256 amountSpecified;
        PoolId poolId;
    }

    struct StateOverride {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
    }

    function getSlot0Assembled(IPoolManager manager, PoolId poolId) internal view returns (Slot0 slot0){
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(poolId);
        slot0 = Slot0.wrap(bytes32(0)).setSqrtPriceX96(sqrtPriceX96).setTick(tick).setProtocolFee(protocolFee).setLpFee(lpFee);
    }

    function swapSim(IPoolManager manager, SwapParams memory params)
        internal
        view
        returns (BalanceDelta result, SwapState memory state)
    {
        return swapSim(manager, StateOverride({sqrtPriceX96: 0, tick: 0, liquidity: 0}), params);
    }

    function swapSim(
        IPoolManager manager, 
        StateOverride memory stateOverride,
        SwapParams memory params
        )
        internal
        view
        returns (BalanceDelta result, SwapState memory state)
    {

        Slot0 slot0Start = getSlot0Assembled(manager, params.poolId);

        bool zeroForOne = params.zeroForOne;

        // uint128 liquidityStart = manager.getLiquidity(params.poolId);
        // uint256 protocolFee =
        //     zeroForOne ? slot0Start.protocolFee().getZeroForOneFee() : slot0Start.protocolFee().getOneForZeroFee();

        state.amountSpecifiedRemaining = params.amountSpecified;
        state.amountCalculated = 0;
        state.sqrtPriceX96 = stateOverride.sqrtPriceX96 > 0? stateOverride.sqrtPriceX96 : slot0Start.sqrtPriceX96();
        state.tick = stateOverride.sqrtPriceX96 > 0? stateOverride.tick : slot0Start.tick();
        // state.feeGrowthGlobalX128 = zeroForOne ? self.feeGrowthGlobal0X128 : self.feeGrowthGlobal1X128;
        state.liquidity = stateOverride.sqrtPriceX96 > 0? stateOverride.liquidity : manager.getLiquidity(params.poolId);

        // if the beforeSwap hook returned a valid fee override, use that as the LP fee, otherwise load from storage
        // {
        //     // uint24 lpFee = params.lpFeeOverride.isOverride()
        //     //     ? params.lpFeeOverride.removeOverrideFlagAndValidate()
        //     //     : lpFeeStart;
        //     uint24 lpFee = slot0Start.lpFee();

        //     swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
        // }
        uint24 swapFee = slot0Start.lpFee();

        bool exactInput = params.amountSpecified < 0;

        if (swapFee == LPFeeLibrary.MAX_LP_FEE && !exactInput) {
            InvalidFeeForExactOut.selector.revertWith();
        }

        if (params.amountSpecified == 0) return (BalanceDeltaLibrary.ZERO_DELTA, state);

        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 >= slot0Start.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 < TickMath.MIN_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 <= slot0Start.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        }

        StepComputations memory step;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (!(state.amountSpecifiedRemaining == 0 || state.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                // self.tickBitmap.nextInitializedTickWithinOneWord(state.tick, params.tickSpacing, zeroForOne);
                manager.nextInitializedTickWithinOneWord(state.tick, params.poolId, params.tickSpacing, zeroForOne);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                state.liquidity,
                state.amountSpecifiedRemaining,
                swapFee
            );

            if (!exactInput) {
                unchecked {
                    state.amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                state.amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                // safe because we test that amountSpecified > amountIn + feeAmount in SwapMath
                unchecked {
                    state.amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                state.amountCalculated += step.amountOut.toInt256();
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            // if (protocolFee > 0) {
            //     unchecked {
            //         // step.amountIn does not include the swap fee, as it's already been taken from it,
            //         // so add it back to get the total amountIn and use that to calculate the amount of fees owed to the protocol
            //         // this line cannot overflow due to limits on the size of protocolFee and params.amountSpecified
            //         uint256 delta = (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
            //         // subtract it from the total fee and add it to the protocol fee
            //         step.feeAmount -= delta;
            //         feeForProtocol += delta;
            //     }
            // }

            // update global fee tracker
            if (state.liquidity > 0) {
                unchecked {
                    state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
                }
            }

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    // (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = zeroForOne
                    //     ? (state.feeGrowthGlobalX128, self.feeGrowthGlobal1X128)
                    //     : (self.feeGrowthGlobal0X128, state.feeGrowthGlobalX128);
                    (,int128 liquidityNet) =
                        // Pool.crossTick(self, step.tickNext, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
                        // self.ticks[step.tickNext].liquidityNet;
                        manager.getTickLiquidity(params.poolId, step.tickNext);
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                // Equivalent to `state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;`
                unchecked {
                    // cannot cast a bool to an int24 in Solidity
                    int24 _zeroForOne;
                    assembly ("memory-safe") {
                        _zeroForOne := and(zeroForOne, 0xff)
                    }
                    state.tick = step.tickNext - _zeroForOne;
                }
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
            }
        }

        // self.slot0 = slot0Start.setTick(state.tick).setSqrtPriceX96(state.sqrtPriceX96);

        // update liquidity if it changed
        // if (liquidityStart != state.liquidity) self.liquidity = state.liquidity;

        // update fee growth global
        // if (!zeroForOne) {
        //     self.feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        // } else {
        //     self.feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        // }

        unchecked {
            if (zeroForOne != exactInput) {
                result = toBalanceDelta(
                    state.amountCalculated.toInt128(),
                    (params.amountSpecified - state.amountSpecifiedRemaining).toInt128()
                );
            } else {
                result = toBalanceDelta(
                    (params.amountSpecified - state.amountSpecifiedRemaining).toInt128(),
                    state.amountCalculated.toInt128()
                );
            }
        }
    }
}