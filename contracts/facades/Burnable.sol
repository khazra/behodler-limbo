// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;


abstract contract Burnable {
    function burn (uint amount) public virtual;
}