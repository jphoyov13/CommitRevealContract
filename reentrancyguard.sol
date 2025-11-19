// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SimpleReentrancyGuard
/// @notice Adds a minimal reentrancy guard to the withdraw function
contract SimpleReentrancyGuard {
    mapping(address => uint256) public balances;

    /// @notice Status flag for reentrancy (0 = not entered, 1 = entered)
    uint256 private status;

    /// @notice Deposit ETH into the contract
    function deposit() external payable {
        require(msg.value > 0, "Must send ETH");
        balances[msg.sender] += msg.value;
    }

    /// @notice Withdraw ETH with reentrancy guard
    function withdraw() external {
        require(status == 0, "Reentrant call");
        status = 1;

        uint256 amount = balances[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Withdraw failed");

        balances[msg.sender] = 0;
        status = 0;
    }

    /// @notice Check the contract's ETH balance
    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
