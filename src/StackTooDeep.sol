// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

contract StackTooDeep {

 function doMath(
   uint a1,
   uint a2,
   uint a3,
   uint a4,
   uint a5,
   uint a6,
   uint a7,
   uint a8,
   uint a9
   ) public pure returns (uint) {
    return a1 + a2 + a3 + a4 + a5 + a6 + a7;
   }

 struct MyStruct{
    uint a;
    uint b;
 }

 function calculate(
   uint a1,
   uint a2,
   uint a3,
   uint a4,
   uint a5,
   uint a6,
   uint a7,
   uint a8,
   uint a9,
   uint a10,
   uint a11,
   MyStruct memory a12
//    uint a13
   ) public pure returns (uint) {
    // while (true)
    // return a1 + a3 + a4 + a5; 
    // return a12 + a11 + a10 + a9 + a8 + a7 + a6 + a5 + a4 + a3 + a2; 
//    return doMath(a1 ,a2 ,a3 , a4 , a5, a6 , a7 , a8, a9);
   // return doMath(a9, a8, a7, a6, a3, a5, a4, a2, a1);
 }
}