// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice ERC-20 test double whose transfer behaviour can be switched after a pool is set up:
///         normal, fee-on-transfer (1% burned), or returning false without moving funds.
contract WeirdToken {
    enum Mode {
        Normal,
        FeeOnTransfer,
        ReturnFalse
    }

    Mode public mode;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function mint(address to_, uint256 amount_) external {
        balanceOf[to_] += amount_;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        return _move(msg.sender, to_, amount_);
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        if (mode == Mode.ReturnFalse) return false;
        allowance[from_][msg.sender] -= amount_;
        return _move(from_, to_, amount_);
    }

    function _move(address from_, address to_, uint256 amount_) internal returns (bool) {
        if (mode == Mode.ReturnFalse) return false;
        balanceOf[from_] -= amount_;
        uint256 received = mode == Mode.FeeOnTransfer ? amount_ - amount_ / 100 : amount_;
        balanceOf[to_] += received;
        return true;
    }
}
