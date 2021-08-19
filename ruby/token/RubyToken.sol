pragma solidity 0.6.6;

import '@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol';

contract RubyToken is ERC20PresetMinterPauser {
    constructor()
        public
        ERC20PresetMinterPauser("Ruby", "gRuby")
    {
        _setupDecimals(18);
    }       
}