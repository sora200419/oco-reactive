// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title TestToken
/// @notice Minimal ERC-20 with open minting, used to build demo pools on testnets. Has no value and
///         must never be deployed to a mainnet.
contract TestToken {
    /// @notice Standard ERC-20 transfer event.
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Standard ERC-20 approval event.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice The sender's balance is too low for the transfer.
    error InsufficientBalance(uint256 balance, uint256 needed);
    /// @notice The spender's allowance is too low for the transfer.
    error InsufficientAllowance(uint256 allowance, uint256 needed);

    /// @notice Token name.
    string public name;
    /// @notice Token symbol.
    string public symbol;
    /// @notice Token decimals.
    uint8 public constant decimals = 18;
    /// @notice Total minted supply.
    uint256 public totalSupply;
    /// @notice Balance of each account.
    mapping(address account => uint256) public balanceOf;
    /// @notice Allowance granted by `owner` to `spender`.
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    /// @notice Mints tokens to any address. Open to everyone: this is a faucet token.
    /// @param to_ Recipient.
    /// @param amount_ Amount to mint.
    function mint(address to_, uint256 amount_) external {
        totalSupply += amount_;
        balanceOf[to_] += amount_;
        emit Transfer(address(0), to_, amount_);
    }

    /// @notice Sets the caller's allowance for `spender_`.
    /// @param spender_ Account allowed to spend.
    /// @param amount_ New allowance.
    /// @return Always true.
    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        emit Approval(msg.sender, spender_, amount_);
        return true;
    }

    /// @notice Transfers tokens from the caller.
    /// @param to_ Recipient.
    /// @param amount_ Amount to transfer.
    /// @return Always true.
    function transfer(address to_, uint256 amount_) external returns (bool) {
        _transfer(msg.sender, to_, amount_);
        return true;
    }

    /// @notice Transfers tokens on behalf of `from_`, spending the caller's allowance.
    /// @param from_ Account to debit.
    /// @param to_ Recipient.
    /// @param amount_ Amount to transfer.
    /// @return Always true.
    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        uint256 allowed = allowance[from_][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount_) revert InsufficientAllowance(allowed, amount_);
            allowance[from_][msg.sender] = allowed - amount_;
        }
        _transfer(from_, to_, amount_);
        return true;
    }

    function _transfer(address from_, address to_, uint256 amount_) internal {
        uint256 balance = balanceOf[from_];
        if (balance < amount_) revert InsufficientBalance(balance, amount_);
        balanceOf[from_] = balance - amount_;
        balanceOf[to_] += amount_;
        emit Transfer(from_, to_, amount_);
    }
}
