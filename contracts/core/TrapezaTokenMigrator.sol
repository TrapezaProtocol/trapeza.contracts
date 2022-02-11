// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/InewsFIDL.sol";
import "./interfaces/IsFIDL.sol";
import "./interfaces/IgFIDL.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/IStakingV1.sol";

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";

contract TrapezaTokenMigrator is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using SafeERC20 for IgFIDL;
  using SafeERC20 for IsFIDL;

  /* ========== STATE VARIABLES ========== */

  IERC20 public FIDL;
  IgFIDL public gFIDL;

  InewsFIDL public newsFIDL;
  IsFIDL public oldsFIDL;

  IStakingV1 public oldStaking;

  IStaking public newStaking;

  bool public shutdown;

  /* ========== EVENTS ========== */

  event Migrated(uint256 sFIDL, uint256 gFIDL);
  event Toggled(bool shutdown);
  event Destroyed(address indexed owner);

  /* ========== CONSTRUCTOR ========== */
  constructor(
    address _FIDL,
    address _gFIDL,
    address _oldsFIDL,
    address _newsFIDL,
    address _oldStaking,
    address _newStaking
  ) {
    require(_FIDL != address(0), "Zero address: FIDL");
    FIDL = IgFIDL(_FIDL);

    require(_gFIDL != address(0), "Zero address: gFIDL");
    gFIDL = IgFIDL(_gFIDL);

    require(_oldsFIDL != address(0), "Zero address: sFIDL");
    oldsFIDL = IsFIDL(_oldsFIDL);

    require(_newsFIDL != address(0), "Zero address: new sFIDL");
    newsFIDL = InewsFIDL(_newsFIDL);

    require(_oldStaking != address(0), "Zero address: Staking");
    oldStaking = IStakingV1(_oldStaking);

    require(_newStaking != address(0), "Zero address: new staking");
    newStaking = IStaking(_newStaking);

    approveForMigrator(_oldsFIDL, _oldStaking);
    approveForMigrator(_FIDL, _newStaking);
  }

  /* ========== OWNABLE ========== */

  /**
   * @notice approve max amount for migrator, only owner available
   * @param _token Token address
   * @param _spender The address to approve
   */
  function approveForMigrator(address _token, address _spender)
    public
    onlyOwner
  {
    IERC20(_token).approve(_spender, uint256(-1));
  }

  /**
   * @notice toggle shutdown
   */
  function halt() external onlyOwner {
    shutdown = !shutdown;

    emit Toggled(shutdown);
  }

  /**
   * @notice destroy migrator
   */
  function destroy() external onlyOwner {
    address zeroAddress = address(0);

    shutdown = true;

    FIDL = IgFIDL(zeroAddress);
    gFIDL = IgFIDL(zeroAddress);
    oldsFIDL = IsFIDL(zeroAddress);
    newsFIDL = InewsFIDL(zeroAddress);
    oldStaking = IStakingV1(zeroAddress);
    newStaking = IStaking(zeroAddress);

    emit Destroyed(msg.sender);
  }

  /* ========== MIGRATION ========== */

  /**
   * @notice migrate sFIDL to gFIDL, tranfer FIDL from oldStaking to newStaking
   * @param _amount sFIDL amount
   */
  function migrate(uint256 _amount) external {
    require(!shutdown, "Shut down");

    uint256 oldsFIDLCirculatingSupply = newsFIDL.oldsFIDLCirculatingSupply();
    require(oldsFIDLCirculatingSupply >= _amount, "Exceed migrate amount");

    oldsFIDL.safeTransferFrom(msg.sender, address(this), _amount);
    oldStaking.unstake(_amount, false);

    FIDL.safeTransfer(address(newStaking), _amount);

    newsFIDL.decreaseOldCirculatingSupply(_amount);

    uint256 gAmount = expect(_amount);

    gFIDL.mint(msg.sender, gAmount); // mint gFIDL to sender;

    emit Migrated(_amount, gAmount);
  }

  /* ========== VIEW FUNCTIONS ========== */

  /**
   * @notice expectation current gFIDL amount from sFIDL
   * @param _amount sFIDL amount
   * @return uint256 gFIDL amount
   */
  function expect(uint256 _amount) public view returns (uint256) {
    return gFIDL.balanceTo(_amount.mul(gFIDL.index()).div(oldsFIDL.index()));
  }
}
