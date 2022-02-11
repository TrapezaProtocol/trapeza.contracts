// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./interfaces/IgFIDL.sol";
import "./interfaces/IsFIDL.sol";
import "./interfaces/IStaking.sol";

import "./libraries/Address.sol";
import "./libraries/SafeMath.sol";

import "./types/ERC20Permit.sol";

contract sTrapeza_V2 is IsFIDL, ERC20Permit {
  /* ========== DEPENDENCIES ========== */

  using SafeMath for uint256;

  /* ========== EVENTS ========== */

  event LogSupply(uint256 indexed epoch, uint256 totalSupply);
  event LogRebase(uint256 indexed epoch, uint256 rebase, uint256 index);
  event LogRebaseAmount(uint256 rebaseAmount);
  event ChangedOldCirculatingSupply(uint256 decreased, uint256 balance);
  event LogContractsUpdated(address stakingContract, address migratorContract, address oldsFIDL);
  event LogTreasuryUpdated(address treasury);
  event OwnershipPushed(address indexed previousOwner, address indexed newOwner);

  /* ========== MODIFIERS ========== */

  modifier onlyStakingContract() {
    require(
      msg.sender == stakingContract,
      "Unauthorized: Only staking"
    );
    _;
  }

    modifier onlyMigrator() {
    require(
      msg.sender == migratorContract,
      "Unauthorized: Only migrator"
    );
    _;
  }

  modifier onlyInitializer() {
    require(
      msg.sender == initializer,
      "Unauthorized: Only Initializer"
    );
    _;
  }

  modifier onlyManager() {
    require(
      msg.sender == manager,
      "Unauthorized: Only Manager"
    );
    _;
  }

  /* ========== DATA STRUCTURES ========== */

  struct Rebase {
    uint256 epoch;
    uint256 rebase; // 18 decimals
    uint256 totalStakedBefore;
    uint256 totalStakedAfter;
    uint256 amountRebased;
    uint256 index;
    uint256 blockNumberOccured;
  }

  /* ========== STATE VARIABLES ========== */

  address internal initializer;
  address internal manager;

  uint256 internal INDEX; // Index Gons - tracks rebase growth

  address public stakingContract; // balance used to calc rebase
  address public migratorContract; // calc rest oldsFIDL circulatingSupply
  IsFIDL public oldsFIDL; // v1 contract
  IgFIDL public gFIDL; // additional staked supply (governance token)

  uint256 public oldsFIDLCirculatingSupply; // block abusing

  Rebase[] public rebases; // past rebase data

  uint256 private constant MAX_UINT256 = type(uint256).max;
  uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 5_000_000 * 10**9;

  // TOTAL_GONS is a multiple of INITIAL_FRAGMENTS_SUPPLY so that _gonsPerFragment is an integer.
  // Use the highest value that fits in a uint256 for max granularity.
  uint256 private constant TOTAL_GONS =
    MAX_UINT256 - (MAX_UINT256 % INITIAL_FRAGMENTS_SUPPLY);

  // MAX_SUPPLY = maximum integer < (sqrt(4*TOTAL_GONS + 1) - 1) / 2
  uint256 private constant MAX_SUPPLY = ~uint128(0); // (2^128) - 1

  uint256 private _gonsPerFragment;
  mapping(address => uint256) private _gonBalances;

  mapping(address => mapping(address => uint256)) private _allowedValue;

  address public treasury;
  mapping(address => uint256) public override debtBalances;

  /* ========== CONSTRUCTOR ========== */

  constructor(uint256 oldTotalSupply_) ERC20("Staked FIDL", "sFIDL", 9) ERC20Permit("Staked FIDL") {
    initializer = msg.sender;
    manager = msg.sender;
    _totalSupply = oldTotalSupply_;
    _gonsPerFragment = TOTAL_GONS.div(_totalSupply);
  }

  /* ========== INITIALIZATION ========== */

  function setIndex(uint256 _index) external onlyInitializer {
    require(INDEX == 0, "Cannot set INDEX again");
    INDEX = gonsForBalance(_index);
  }

  function setgFIDL(address _gFIDL) external onlyInitializer {
    require(address(gFIDL) == address(0), "gFIDL: Already set");
    require(_gFIDL != address(0), "gFIDL: Not address");
    gFIDL = IgFIDL(_gFIDL);
  }

  // do this last
  function initialize(address stakingContract_, address migratorContract_, address oldsFIDL_) external onlyInitializer {
    require(stakingContract_ != address(0), "Zero address: Staking");
    stakingContract = stakingContract_;

    require(migratorContract_ != address(0), "Zero address: Migrator");
    migratorContract = migratorContract_;

    require(oldsFIDL_ != address(0), "Zero address: oldsFIDL");
    oldsFIDL = IsFIDL(oldsFIDL_);

    oldsFIDLCirculatingSupply = oldsFIDL.circulatingSupply();

    _gonBalances[stakingContract] = TOTAL_GONS;

    emit Transfer(address(0x0), stakingContract_, _totalSupply);
    emit LogContractsUpdated(stakingContract_, migratorContract_, oldsFIDL_);

    initializer = address(0);
    emit OwnershipPushed(initializer, address(0));
  }

  function setTreasury(address _treasury) external onlyManager {
    require(_treasury != address(0), "Zero address: Treasury");
    treasury = _treasury;

    emit LogTreasuryUpdated(_treasury);
  }

  function renounceManager() external onlyManager {
    emit OwnershipPushed(manager, address(0));

    manager = address(0);
  }

  /* ========== REBASE ========== */

  /**
        @notice increases sFIDL supply to increase staking balances relative to profit_
        @param profit_ uint256
        @return uint256
     */
  function rebase(uint256 profit_, uint256 epoch_)
    public
    override
    onlyStakingContract
    returns (uint256)
  {
    uint256 rebaseAmount;
    uint256 circulatingSupply_ = circulatingSupply();
    if (profit_ == 0) {
      emit LogSupply(epoch_, _totalSupply);
      emit LogRebase(epoch_, 0, index());
      return _totalSupply;
    } else if (circulatingSupply_ > 0) {
      rebaseAmount = profit_.mul(_totalSupply).div(circulatingSupply_);
    } else {
      rebaseAmount = profit_;
    }

    _totalSupply = _totalSupply.add(rebaseAmount);

    if (_totalSupply > MAX_SUPPLY) {
      _totalSupply = MAX_SUPPLY;
    }

    _gonsPerFragment = TOTAL_GONS.div(_totalSupply);

    _storeRebase(circulatingSupply_, profit_, epoch_);
    emit LogRebaseAmount(rebaseAmount);

    return _totalSupply;
  }

  /**
        @notice emits event with data about rebase
        @param previousCirculating_ uint
        @param profit_ uint
        @param epoch_ uint
     */
  function _storeRebase(
    uint256 previousCirculating_,
    uint256 profit_,
    uint256 epoch_
  ) internal {
    uint256 rebasePercent = profit_.mul(1e18).div(previousCirculating_);
    rebases.push(
      Rebase({
        epoch: epoch_,
        rebase: rebasePercent, // 18 decimals
        totalStakedBefore: previousCirculating_,
        totalStakedAfter: circulatingSupply(),
        amountRebased: profit_,
        index: index(),
        blockNumberOccured: block.number
      })
    );

    emit LogSupply(epoch_, _totalSupply);
    emit LogRebase(epoch_, rebasePercent, index());
  }

  /* ========== MUTATIVE FUNCTIONS =========== */

  function transfer(address to, uint256 value)
    public
    override(IERC20, ERC20)
    returns (bool)
  {
    uint256 gonValue = value.mul(_gonsPerFragment);

    _gonBalances[msg.sender] = _gonBalances[msg.sender].sub(gonValue);
    _gonBalances[to] = _gonBalances[to].add(gonValue);

    require(
      balanceOf(msg.sender) >= debtBalances[msg.sender],
      "Debt: cannot transfer amount"
    );
    emit Transfer(msg.sender, to, value);
    return true;
  }

  function transferFrom(
    address from,
    address to,
    uint256 value
  ) public override(IERC20, ERC20) returns (bool) {
    _allowedValue[from][msg.sender] = _allowedValue[from][msg.sender].sub(
      value
    );
    emit Approval(from, msg.sender, _allowedValue[from][msg.sender]);

    uint256 gonValue = gonsForBalance(value);
    _gonBalances[from] = _gonBalances[from].sub(gonValue);
    _gonBalances[to] = _gonBalances[to].add(gonValue);

    require(
      balanceOf(from) >= debtBalances[from],
      "Debt: cannot transfer amount"
    );
    emit Transfer(from, to, value);
    return true;
  }

  function approve(address spender, uint256 value)
    public
    override(IERC20, ERC20)
    returns (bool)
  {
    _approve(msg.sender, spender, value);
    return true;
  }

  function increaseAllowance(address spender, uint256 addedValue)
    public
    override
    returns (bool)
  {
    _approve(
      msg.sender,
      spender,
      _allowedValue[msg.sender][spender].add(addedValue)
    );
    return true;
  }

  function decreaseAllowance(address spender, uint256 subtractedValue)
    public
    override
    returns (bool)
  {
    uint256 oldValue = _allowedValue[msg.sender][spender];
    if (subtractedValue >= oldValue) {
      _approve(msg.sender, spender, 0);
    } else {
      _approve(msg.sender, spender, oldValue.sub(subtractedValue));
    }
    return true;
  }

  function decreaseOldCirculatingSupply(uint256 _migrateAmount)
    public
    onlyMigrator
  {
    if (oldsFIDLCirculatingSupply >= _migrateAmount) {
      oldsFIDLCirculatingSupply -= _migrateAmount;
    } else {
      oldsFIDLCirculatingSupply = 0;
    }

    emit ChangedOldCirculatingSupply(_migrateAmount, oldsFIDLCirculatingSupply);
  }

  function decreaseOldCirculatingSupplyByUnstaking(uint256 _unstakedAmount)
    public
    onlyManager
  {
    require(oldsFIDLCirculatingSupply >= _unstakedAmount, "Exceeded amount");
    oldsFIDLCirculatingSupply -= _unstakedAmount;

    emit ChangedOldCirculatingSupply(_unstakedAmount, oldsFIDLCirculatingSupply);
  }

  // this function is called by the treasury, and informs sFIDL of changes to debt.
  // note that addresses with debt balances cannot transfer collateralized sFIDL
  // until the debt has been repaid.
  function changeDebt(
    uint256 amount,
    address debtor,
    bool add
  ) external override {
    require(msg.sender == treasury, "Only treasury");

    if (add) {
      debtBalances[debtor] = debtBalances[debtor].add(amount);
    } else {
      debtBalances[debtor] = debtBalances[debtor].sub(amount);
    }

    require(
      debtBalances[debtor] <= balanceOf(debtor),
      "sFIDL: insufficient balance"
    );
  }

  /* ========== INTERNAL FUNCTIONS ========== */

  function _approve(
    address owner,
    address spender,
    uint256 value
  ) internal virtual override {
    _allowedValue[owner][spender] = value;
    emit Approval(owner, spender, value);
  }

  /* ========== VIEW FUNCTIONS ========== */

  function balanceOf(address who)
    public
    view
    override(IERC20, ERC20)
    returns (uint256)
  {
    return _gonBalances[who].div(_gonsPerFragment);
  }

  function gonsForBalance(uint256 amount)
    public
    view
    override
    returns (uint256)
  {
    return amount.mul(_gonsPerFragment);
  }

  function balanceForGons(uint256 gons) public view override returns (uint256) {
    return gons.div(_gonsPerFragment);
  }

  // toG converts an sFIDL balance to gFIDL terms. gFIDL is an 18 decimal token. balance given is in 18 decimal format.
  function toG(uint256 amount) external view override returns (uint256) {
    return gFIDL.balanceTo(amount);
  }

  // fromG converts a gFIDL balance to sFIDL terms. sFIDL is a 9 decimal token. balance given is in 9 decimal format.
  function fromG(uint256 amount) external view override returns (uint256) {
    return gFIDL.balanceFrom(amount);
  }

  // Staking contract holds excess sFIDL
  function circulatingSupply() public view override returns (uint256) {
    return
      _totalSupply
        .sub(balanceOf(stakingContract))
        .add(balanceForGons(oldsFIDL.gonsForBalance(oldsFIDLCirculatingSupply)))
        .add(gFIDL.balanceFrom(gFIDL.totalSupply()))
        .add(IStaking(stakingContract).supplyInWarmup());
  }

  function index() public view override returns (uint256) {
    return balanceForGons(INDEX);
  }

  function allowance(address owner_, address spender)
    public
    view
    override(IERC20, ERC20)
    returns (uint256)
  {
    return _allowedValue[owner_][spender];
  }
}
