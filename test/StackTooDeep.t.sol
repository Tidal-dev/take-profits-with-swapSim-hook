// SPDX-License-Identifier: UNLICENSE
pragma solidity ^0.8.0;

import {StackTooDeep} from "../src/StackTooDeep.sol";
import "forge-std/Test.sol";

contract ContractBTest is Test {
    StackTooDeep stackTooDeep;

    function setUp() public {
        stackTooDeep = new StackTooDeep();
    }

    
    function test_calculate() private view {
        StackTooDeep.MyStruct memory myStruct = StackTooDeep.MyStruct ({
            a: 10,
            b: 10
        });
        uint result = stackTooDeep.calculate(1,1,1,1,1,1,1,1,1,1,1,myStruct);
        assertEq(result, 9);
    }
}