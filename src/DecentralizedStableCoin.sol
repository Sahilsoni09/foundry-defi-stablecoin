// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "lib/openzepplin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "lib/openzepplin-contracts/contracts/access/Ownable.sol";
/**
 * @title DecentralizedStableCoin
 * @author Sahil Soni
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * this is the contract meant  to be governed by DSCEngine. This Contract is just the ERC20 implementation of our stablecoin system
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BrunAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        if (balance < _amount) {
            revert DecentralizedStableCoin__BrunAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns(bool){

        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        _mint(_to, _amount);
        return true;

    }
}
