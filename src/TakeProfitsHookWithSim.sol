// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencyDelta} from "v4-core/libraries/CurrencyDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, add, sub} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary,toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {SwapSim} from "./libraries/SwapSim.sol";

import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";

import "forge-std/console.sol";

contract TakeProfitsHookWithSim is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SwapSim for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencyDelta for Currency;
    using FixedPointMathLib for uint256;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    // Storage
    mapping(PoolId poolId => int24 lastTick) public lastTicks;
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount)))
        public pendingOrders;

    mapping(uint256 positionId => uint256 outputClaimable)
        public claimableOutputTokens;
    mapping(uint256 positionId => uint256 claimsSupply)
        public claimTokensSupply;

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // Constructor
    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}

    // BaseHook Functions
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4) {
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4, BeforeSwapDelta, uint24) {

        // `sender` is the address which initiated the swap
        // if `sender` is the hook, we don't want to go down the `afterSwap`
        // rabbit hole again
        if (sender == address(this)) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
// console.log("token0Balance init : ", key.currency0.balanceOf(address(this)));
// console.log("token1Balance init : ", key.currency1.balanceOf(address(this)));

        // SwapSim.SwapParams memory simParams = SwapSim.SwapParams({
        //     zeroForOne: params.zeroForOne,
        //     amountSpecified: params.amountSpecified,
        //     sqrtPriceLimitX96: params.sqrtPriceLimitX96,
        //     tickSpacing: key.tickSpacing,
        //     poolId: key.toId()
        // });

        (BalanceDelta userDeltaToHook, SwapSim.SwapState memory state) = poolManager.swapSim(
            SwapSim.SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                tickSpacing: key.tickSpacing,
                poolId: key.toId()
            })
        );
            console.log("tick after user swapsim : ", state.tick);
            // console.log("userDeltaToHook : ", userDeltaToHook.amount0());
            // console.log("userDeltaToHook : ", userDeltaToHook.amount1());
        SwapSim.StateOverride memory stateOverride = SwapSim.StateOverride({
            sqrtPriceX96: state.sqrtPriceX96,
            tick: state.tick,
            liquidity: state.liquidity
        });
        
        BalanceDelta hookDeltaToPM;
        {
            PoolKey memory poolKey = key;

            (, BalanceDelta finalDeltaSim) = 
                afterSwapSim(key, userDeltaToHook, stateOverride);
// console.log("Final Delta Sim : ", finalDeltaSim.amount0());
// console.log("Final Delta Sim : ", finalDeltaSim.amount1());

            hookDeltaToPM = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: finalDeltaSim.amount0() < 0,
                    // We provide a negative value here to signify an "exact input for output" swap
                    amountSpecified: finalDeltaSim.amount0() < 0? finalDeltaSim.amount0() : finalDeltaSim.amount1(),
                    // No slippage limits (maximum slippage possible)
                    sqrtPriceLimitX96: finalDeltaSim.amount0() < 0
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );

            // userDeltaToHook = sub(hookDeltaToPM, userDeltaToHook);
            // console.log("hookDeltaToPM : ", hookDeltaToPM.amount0());
            // console.log("hookDeltaToPM : ", hookDeltaToPM.amount1());
            // Return skipped gas fees to LPs
            uint256 amountToReturnToLPs =   
                finalDeltaSim.amount0() < 0? uint256(uint128(hookDeltaToPM.amount1() - finalDeltaSim.amount1())) :
                    uint256(uint128(hookDeltaToPM.amount0() - finalDeltaSim.amount0()));
// console.log("amountToReturnToLPs : ", amountToReturnToLPs);
            
            BalanceDelta afterDonateDelta = poolManager.donate(
                poolKey,
                finalDeltaSim.amount0() < 0? 0 : amountToReturnToLPs,
                finalDeltaSim.amount0() < 0? amountToReturnToLPs : 0,
                "0x0"    
            );

            hookDeltaToPM = add(hookDeltaToPM, afterDonateDelta);
            // console.log("New hookDeltaToPM Delta after Fees : ", hookDeltaToPM.amount0());
            // console.log("New hookDeltaToPM Delta after Fees: ", hookDeltaToPM.amount1());
        }
        {
            (,int24 finalTick,,) = poolManager.getSlot0(key.toId());
            console.log("actual TICK after swap : ", finalTick);
        }
// console.log("Currency0 to settle before settle : ",poolManager.currencyDelta(address(this), key.currency0));
//         console.log("Currency1 to settle before settle : ",poolManager.currencyDelta(address(this), key.currency1));
        console.log("CHECK");
        {
            BalanceDelta hookDeltaToSettle = sub(hookDeltaToPM, userDeltaToHook);
            // console.log("hookDeltaToSettle : ", hookDeltaToSettle.amount0());
            // console.log("hookDeltaToSettle : ", hookDeltaToSettle.amount1());
            if (hookDeltaToSettle.amount0() > 0) {

                _take(key.currency0, uint128(hookDeltaToSettle.amount0()));

                _settle(key.currency1, uint128(-hookDeltaToSettle.amount1()));
            } else {
                
                _settle(key.currency0, uint128(-hookDeltaToSettle.amount0()));

                _take(key.currency1, uint128(hookDeltaToSettle.amount1()));
            }
        }

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified),
            params.zeroForOne? 
                (params.amountSpecified < 0? -userDeltaToHook.amount1() : -userDeltaToHook.amount0())
                :   (params.amountSpecified < 0? -userDeltaToHook.amount0() : -userDeltaToHook.amount1())
        );
        
//         console.log("beforeSwapDelta : ", beforeSwapDelta.getSpecifiedDelta());
//         console.log("beforeSwapDelta : ", beforeSwapDelta.getUnspecifiedDelta());
//         console.log("token0Balance end : ", key.currency0.balanceOf(address(this)));
// console.log("token1Balance end : ", key.currency1.balanceOf(address(this)));
// console.log("Currency0 to settle after settle : ",poolManager.currencyDelta(address(this), key.currency0));
//         console.log("Currency1 to settle after settle : ",poolManager.currencyDelta(address(this), key.currency1));
        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }


    // Core Hook External Functions
    function placeOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        // Get lower actually usable tick given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        // Mint claim tokens to user equal to their `inputAmount`
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");

        // Depending on direction of swap, we select the proper input token
        // and request a transfer of those tokens to the hook contract
        address sellToken = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        // Return the tick at which the order was actually placed
        return tick;
    }

    function cancelOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne
    ) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // Check how many claim tokens they have for this position
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens == 0) revert InvalidOrder();

        // Remove their `positionTokens` worth of position from pending orders
        // NOTE: We don't want to zero this out directly because other users may have the same position
        pendingOrders[key.toId()][tick][zeroForOne] -= positionTokens;
        // Reduce claim token total supply and burn their share
        claimTokensSupply[positionId] -= positionTokens;
        _burn(msg.sender, positionId, positionTokens);

        // Send them their input token
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, positionTokens);
    }

    function redeem(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmountToClaimFor
    ) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // If no output tokens can be claimed yet i.e. order hasn't been filled
        // throw error
        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        // they must have claim tokens >= inputAmountToClaimFor
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];

        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForPosition,
            totalInputAmountForPosition
        );

        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        // Transfer output tokens
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    function afterSwapSim(
        PoolKey calldata key,
        BalanceDelta deltaSim,
        SwapSim.StateOverride memory stateOverride
    ) private returns (int24, BalanceDelta) {
        (, int24 realTick, , ) = poolManager.getSlot0(key.toId());
        int24 currentTick = stateOverride.tick;
        bool zeroForOne = currentTick > realTick;
        bool invertAndTryAgain = true;

        while(invertAndTryAgain)
        {
            // Try executing pending orders for this pool
            (stateOverride, deltaSim) = tryExecutingOrders(
                key,
                zeroForOne,
                stateOverride.tick,
                deltaSim,
                stateOverride
            );
            currentTick = stateOverride.tick;
            // New last known tick for this pool is the tick value
            // after our orders are executed
            // lastTicks[key.toId()] = currentTick;

            if(zeroForOne != (currentTick > realTick)){
                console.log("INVERT");
                zeroForOne = !zeroForOne;
            }
            else{
                console.log("DONT INVERT");
                invertAndTryAgain = false;
            }
        }
        
        return (currentTick, deltaSim);
    }
    
    // Internal Functions
    function tryExecutingOrders(
        PoolKey calldata key,
        bool executeZeroForOne,
        int24 currentTick,
        BalanceDelta deltaSim,
        SwapSim.StateOverride memory stateOverride
    ) internal returns (SwapSim.StateOverride memory newStateOverride, BalanceDelta finalDelta) {

        int24 lastTick = lastTicks[key.toId()];
        bool tryMore = true;
        int24 tick;
        console.log("last tick : ", lastTick);
        console.log("current tick : ", currentTick);

        // ------------
        // Case (1)
        // ------------

        // Tick has increased i.e. people bought Token 0 by selling Token 1
        // i.e. Token 0 price has increased
        // e.g. in an ETH/USDC pool, people are buying ETH for USDC causing ETH price to increase
        // We should check if we have any orders looking to sell Token 0
        // at ticks `lastTick` to `currentTick`
        // i.e. check if we have any orders to sell ETH at the new price that ETH is at now because of the increase
        if (currentTick > lastTick) {console.log("currentTick > lastTick");
            // Loop over all ticks from `lastTick` to `currentTick`
            // and execute orders that are looking to sell Token 0
            while(tryMore) {
                tryMore = false;
                for (
                    tick = lastTick;
                    tick < currentTick;
                    tick += key.tickSpacing
                ) {
                    uint256 inputAmount = pendingOrders[key.toId()][tick][
                        executeZeroForOne
                    ];
                    if (inputAmount > 0) {
                        // An order with these parameters can be placed by one or more users
                        // We execute the full order as a single swap
                        // Regardless of how many unique users placed the same order
                        (deltaSim, stateOverride) = 
                            executeOrder(key, tick, executeZeroForOne, inputAmount, deltaSim, stateOverride); 
                        tryMore = true; 
                    
                        lastTick = tick;
                        // currentTick = stateOverride.tick;
                    }

                }
            }
            console.log("stateOverride.tick : ",stateOverride.tick);
            lastTicks[key.toId()] = tick;
            return (stateOverride, deltaSim);
        }
        // ------------
        // Case (2)
        // ------------
        // Tick has gone down i.e. people bought Token 1 by selling Token 0
        // i.e. Token 1 price has increased
        // e.g. in an ETH/USDC pool, people are selling ETH for USDC causing ETH price to decrease (and USDC to increase)
        // We should check if we have any orders looking to sell Token 1
        // at ticks `currentTick` to `lastTick`
        // i.e. check if we have any orders to buy ETH at the new price that ETH is at now because of the decrease
        else {console.log("currentTick < lastTick");
            while (tryMore) {
                tryMore = false;
                for (
                    tick = lastTick;
                    tick > currentTick;
                    tick -= key.tickSpacing
                ) {
                    uint256 inputAmount = pendingOrders[key.toId()][tick][
                        executeZeroForOne
                    ];
                    if (inputAmount > 0) {
                        (deltaSim, stateOverride) = 
                            executeOrder(key, tick, executeZeroForOne, inputAmount, deltaSim, stateOverride);
                        tryMore = true;
                    
                        lastTick = tick;
                        currentTick = stateOverride.tick;
                    }
                }
            }console.log("stateOverride.tick : ",stateOverride.tick);
            lastTicks[key.toId()] = tick;
            return (stateOverride, deltaSim);
        }
    }

    function executeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount,
        BalanceDelta deltaSim,
        SwapSim.StateOverride memory stateOverride
    ) internal returns (BalanceDelta, SwapSim.StateOverride memory) {
        // Do the actual swap and settle all balances
        (BalanceDelta delta, SwapSim.SwapState memory state) = poolManager.swapSim(
            stateOverride,
            SwapSim.SwapParams({
                zeroForOne: zeroForOne,
                // We provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1,
                tickSpacing: key.tickSpacing,
                poolId: key.toId()
            })
        );

        // console.log("tick executed : ", tick);
        // console.log("tick after swap sim : ", state.tick);

        // `inputAmount` has been deducted from this position
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));

        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[positionId] += outputAmount;
        // console.log("claimable order amount : ", claimableOutputTokens[positionId]);
        return(
            add(deltaSim, delta),
            SwapSim.StateOverride({
                sqrtPriceX96: state.sqrtPriceX96,
                tick: state.tick,
                liquidity: state.liquidity
            })
        );
    }

    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }

    // Helper Functions
    function getPositionId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    function getLowerUsableTick(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        // E.g. tickSpacing = 60, tick = -100
        // closest usable tick rounded-down will be -120

        // intervals = -100/60 = -1 (integer division)
        int24 intervals = tick / tickSpacing;

        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity

        // actual usable tick, then, is intervals * tickSpacing
        // i.e. -2 * 60 = -120
        return intervals * tickSpacing;
    }
}
