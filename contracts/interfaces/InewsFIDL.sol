// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

import "./IERC20.sol";

interface InewsFIDL is IERC20 {
  function oldsFIDLCirculatingSupply() external view returns (uint256);

  function decreaseOldCirculatingSupply(uint256 _migrateAmount) external;
}
