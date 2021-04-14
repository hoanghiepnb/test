pragma solidity ^0.7.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";


contract PawnContract is Ownable, Pausable {
    uint256 public numberCollaterals;
    uint256 public numberOffers;
    uint256 public numberContracts;
    uint256 public numberPaymentHistory;

    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    enum CollateralStatus {OPEN, DOING, COMPLETED, CANCEL}
    struct Collateral {
        address owner;
        uint256 amount;
        address collateralAddress;
        address loanAsset;
        uint256 expectedDurationQty;
        uint256 expectedDurationType;
        CollateralStatus status;
    }

    enum OfferStatus {PENDING, ACCEPTED, COMPLETED, CANCEL}
    enum RepaymentCycleType {WEEK, MONTH}
    enum LoanDurationType {WEEK, MONTH}
    struct Offer {
        address owner;
        uint256 collateralId;
        address repaymentAsset;
        uint256 loanAmount;
        uint256 interest;
        uint256 duration;
        OfferStatus status;
        LoanDurationType loanDurationType;
        RepaymentCycleType repaymentCycleType;
        uint256 fines;
        uint256 risk;
    }

    enum ContractStatus {ACTIVE, COMPLETED}

    struct Contract {
        uint256 collateralId;
        uint256 offerId;
        uint256 currentRepaymentPhase;
        uint256 penalty;
        ContractStatus status;
        uint256 createdAt;
    }

    struct PaymentHistory {
        uint256 contractId;
        address payerAddress;
        uint256 repaymentPhase;
        uint256 payForLoan;
        uint256 payForInterest;
        uint256 payForFines;
        address paymentToken;
        uint256 createAt;
    }

    struct RepaymentPhase {
        uint256 remainingLoan;
        uint256 remainingInterest;
        uint256 remainingFines;
        uint256 paidForInterest;
        uint256 paidForLoan;
        uint256 paidForFines;
        uint256 createdAt;
        uint256 expiration;
    }

    mapping (uint256 => Offer) public offers;
    mapping (uint256 => Collateral) public collaterals;
    mapping (uint256 => Contract) public contracts;
    mapping (uint256 => PaymentHistory) public paymentHistories;
    mapping (uint256 => mapping(uint256 => RepaymentPhase)) public repaymentPhases;
    mapping (address => uint256) whitelistCollateral;
    mapping (address => mapping(uint256 => uint256)) public lastOffer;
    mapping (address => uint256) systemFee;

    address public operator;
    uint256 public penalty;
    uint256 public ZOOM;
    bool public initialized = false;
    address coldWallet;

    event CreateOffer(
        uint256 _offerId,
        uint256 _collateralId,
        address _offerOwner,
        address _repaymentAsset,
        address _supplyCurrencyAsset,
        uint256 _loanAmount,
        uint256 _duration,
        uint256 _interest,
        uint256 _loanDuration,
        uint256 _repaymentCycleType,
        uint256 _fines,
        uint256 _risk
    );

    event CreateCollateral(
        uint256 _collateralId,
        uint256 _amount,
        address _walletAddress,
        address _cryptoAsset,
        address _expectedCryptoAssetSymbol,
        uint256 _expectedDurationQty,
        uint256 _expectedDurationType
    );

    event CancelOffer(
        uint256 _offerId,
        address _offerOwner
    );

    event WithdrawCollateral(
        uint256 _collateralId,
        address _collateralOwner
    );

    event AcceptOffer(
        uint256 _contractId,
        uint256 _collateralId,
        uint256 _offerId,
        address _offerOwner,
        uint256 _startContract,
        uint256 _endContract
    );

    event Repayment(
        uint256 _paymentHistory,
        uint256 _contractId,
        uint256 _phase,
        address _paymentToken,
        uint256 _payForInterest,
        uint256 _payForLoan,
        uint256 _payForFines
    );

    event Liquidity(
        address _transferTo,
        uint256 _amount,
        uint256 _status
    );

    modifier notInitialized() {
        require(!initialized, "initialized");
        _;
    }

    /**
     * @dev initialize function
     * @param _operator is operator address of this contract
     * @param _zoom is coefficient used to represent risk params
     * @param _penalty is number of overdue debt payments
     */

    function initialize(
        address _operator,
        uint256 _zoom,
        uint256 _penalty,
        address _coldWallet
    ) public notInitialized {
        operator = _operator;
        ZOOM = _zoom;
        penalty = _penalty;
        coldWallet = _coldWallet;
        initialized = true;
    }

    /**
    * @dev set fee for each token
    * @param _token is address of token
    * @param _fee is amount of tokens to pay for the transaction
    */

    function setSystemFee(address _token, uint256 _fee) external onlyOperator {
        systemFee[_token] = _fee;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "caller is not the operator");
        _;
    }

    function setWhitelistCollateral(address _token, uint256 _status) external onlyOperator{
        whitelistCollateral[_token] = _status;
    }

    /**
    * @dev create Collateral function, collateral will be stored in this contract
    * @param _collateralAddress is address of collateral
    * @param _amount is amount of collateral token
    * @param _loanAsset is address of loan token
    * @param _expectedDurationQty is expect duration
    * @param _expectedDurationType is expect duration type
    */
    function createCollateral(
        address _collateralAddress,
        uint256 _amount,
        address _loanAsset,
        uint256 _expectedDurationQty,
        uint256 _expectedDurationType
    ) public whenNotPaused payable
    returns (uint256 _idx)
    {
        //check whitelist collateral token
        require(whitelistCollateral[_collateralAddress] == 1, 'not-support-collateral');
        if (_collateralAddress != address(0)) {
            // transfer to this contract
            ERC20(_collateralAddress).safeTransferFrom(msg.sender, address(this), _amount);
            ERC20(_collateralAddress).safeTransferFrom(msg.sender, address(this), systemFee[_collateralAddress]);
        } else {
            _amount = msg.value;
        }
        //id of collateral
        _idx = numberCollaterals;

        //create new collateral
        Collateral storage newCollateral = collaterals[_idx];
        newCollateral.owner = msg.sender;
        newCollateral.amount = _amount;
        newCollateral.collateralAddress = _collateralAddress;
        newCollateral.loanAsset = _loanAsset;
        newCollateral.status = CollateralStatus.OPEN;
        newCollateral.expectedDurationQty = _expectedDurationQty;
        newCollateral.expectedDurationType = _expectedDurationType;

        ++numberCollaterals;

        emit CreateCollateral(_idx, _amount, msg.sender, _collateralAddress, _loanAsset, _expectedDurationQty, _expectedDurationType);
    }

    /**
    * @dev create Collateral function, collateral will be stored in this contract
    * @param _collateralId is id of collateral
    * @param _repaymentAsset is address of repayment token
    * @param _duration is duration of this offer
    * @param _loanDurationType is type for calculating loan duration
    * @param _repaymentCycleType is type for calculating repayment cycle
    * @param _fines the amount payable for an overdue payment
    * @param _risk is ratio of assets to be liquidated
    */

    function createOffer(
        uint256 _collateralId,
        address _repaymentAsset,
        uint256 _loanAmount,
        uint256 _duration,
        uint256 _interest,
        uint256 _loanDurationType,
        uint256 _repaymentCycleType,
        uint256 _fines,
        uint256 _risk
    )
    public whenNotPaused
    returns (uint256 _idx)
    {
        // each address can create only 1 offer
        require(lastOffer[msg.sender][_collateralId] == 0, 'has-offer-before');
        lastOffer[msg.sender][_collateralId] = 1;

        _idx = numberOffers;
        Offer storage newOffer = offers[_idx];
        newOffer.collateralId = _collateralId;
        newOffer.owner = msg.sender;
        newOffer.repaymentAsset = _repaymentAsset;
        newOffer.loanAmount = _loanAmount;
        newOffer.duration = _duration;
        newOffer.interest = _interest;
        newOffer.loanDurationType = LoanDurationType(_loanDurationType);
        newOffer.repaymentCycleType = RepaymentCycleType(_repaymentCycleType);
        newOffer.fines = _fines;
        newOffer.risk = _risk;
        newOffer.status = OfferStatus.PENDING;
        ++numberOffers;

        Collateral memory collateral = collaterals[_collateralId];
        emit CreateOffer(_idx, _collateralId, msg.sender, _repaymentAsset, collateral.loanAsset,
            _loanAmount, _duration, _interest, _loanDurationType, _repaymentCycleType, _fines, _risk);
    }

    /**
    * @dev cancel offer function, used for cancel offer
    * @param  _offerId is id of offer
    */
    function cancelOffer(uint256 _offerId) public {
        Offer storage offer = offers[_offerId];
        require(offer.owner == msg.sender, 'not-owner-of-offer');
        require(offer.status == OfferStatus.PENDING, 'offer-executed');
        offer.status = OfferStatus.CANCEL;
        emit CancelOffer(_offerId, msg.sender);
    }

    /**
    * @dev cancel collateral function and return back collateral
    * @param  _collateralId is id of collateral
    */
    function withdrawCollateral(uint256 _collateralId) public {
        Collateral storage collateral = collaterals[_collateralId];
        require(collateral.owner == msg.sender, 'not-owner-of-this-collateral');
        require(collateral.status == CollateralStatus.OPEN, 'collateral-not-open');
        if (collateral.collateralAddress != address(0)) {
            // transfer collateral to collateral's owner
            ERC20(collateral.collateralAddress).transfer(collateral.owner, collateral.amount);
        } else {
            payable(collateral.owner).transfer(collateral.amount);
        }
        collateral.status = CollateralStatus.CANCEL;
        emit WithdrawCollateral(_collateralId, msg.sender);
    }

    function calculationOfferDuration(uint256 _offerId)
    internal
    returns (uint256 duration)
    {
        Offer memory offer = offers[_offerId];
        if (offer.loanDuration == LoanDurationType.WEEK) {
            duration = 7 * 24 * 3600 * offer.duration;
        } else {
            duration = 30 * 24 * 3600 * offer.duration;
        }
    }


    /**
        * @dev accept offer and create contract between collateral and offer
        * @param  _collateralId is id of collateral
        * @param  _offerId is id of offer
        */
    function acceptOffer(uint256 _collateralId, uint256 _offerId) public whenNotPaused {
        Offer storage offer = offers[_offerId];
        Collateral storage collateral = collaterals[_collateralId];
        require(msg.sender == collateral.owner, 'not-collateral-owner');
        require(_collateralId == offer.collateralId, 'collateralId-not-match-offerId');
        require(collateral.status == CollateralStatus.OPEN, '-collateral-not-open');
        require(offer.status == OfferStatus.PENDING, 'offer-unavailable');

        //transfer loan asset to collateral owner
        ERC20(collateral.loanAsset).safeTransferFrom(offer.owner, collateral.owner, offer.loanAmount);
        //transfer systemFee to this contract
        ERC20(collateral.loanAsset).safeTransferFrom(offer.owner, address(this), systemFee[collateral.loanAsset]);

        uint256 contractId = createContract(_collateralId, _offerId);
        //change status of offer and collateral
        offer.status = OfferStatus.ACCEPTED;
        collateral.status = CollateralStatus.DOING;
        emit AcceptOffer(contractId, _collateralId, _offerId, msg.sender, block.timestamp, block.timestamp + calculationOfferDuration(_offerId));
    }


    /**
        * @dev create contract between collateral and offer
        * @param  _collateralId is id of collateral
        * @param  _offerId is id of offer
        */

    function createContract (
        uint256 _collateralId,
        uint256 _offerId
    )
    internal
    returns (uint256 _idx)
    {
        _idx = numberContracts;
        Contract storage newContract = contracts[_idx];
        newContract.collateralId = _collateralId;
        newContract.status = ContractStatus.ACTIVE;
        newContract.offerId = _offerId;
        newContract.createdAt = block.timestamp;
        newContract.currentRepaymentPhase = 0;
        ++numberContracts;
    }


    /**
        * @dev repayment for pawn contract
        * @param  _contractId is id contract
        */

    function repayment(
        uint256 _contractId,
        uint256 _payForInterest,
        uint256 _payForLoan,
        uint256 _payForFines
    )
    public
    {
        Contract storage _contract = contracts[_contractId];
        RepaymentPhase storage repaymentPhase = repaymentPhases[_contractId][_contract.currentRepaymentPhase];
        Offer storage offer = offers[_contract.offerId];

        require(_contract.status == ContractStatus.ACTIVE, 'contract-inactive');
        require(block.timestamp <= repaymentPhase.expiration, 'repayment-phase-expired');

        if (_payForInterest > repaymentPhase.remainingInterest) {
            _payForInterest = repaymentPhase.remainingInterest;
        }
        if (_payForLoan > repaymentPhase.remainingLoan) {
            _payForLoan = repaymentPhase.remainingLoan;
        }
        if (_payForFines > repaymentPhase.remainingFines) {
            _payForFines = repaymentPhase.remainingFines;
        }
        repaymentPhase.remainingInterest = repaymentPhase.remainingInterest.sub(_payForInterest);
        repaymentPhase.remainingLoan = repaymentPhase.remainingLoan.sub(_payForLoan);
        repaymentPhase.remainingFines = repaymentPhase.remainingFines.sub(_payForFines);
        repaymentPhase.paidForInterest = repaymentPhase.paidForInterest.add(_payForInterest);
        repaymentPhase.paidForLoan = repaymentPhase.paidForLoan.add(_payForLoan);
        repaymentPhase.paidForFines = repaymentPhase.paidForFines.add(_payForFines);

        ERC20(offer.repaymentAsset).safeTransferFrom(msg.sender, offer.owner, _payForInterest);
        ERC20(offer.repaymentAsset).safeTransferFrom(msg.sender, offer.owner, _payForLoan);
        ERC20(offer.repaymentAsset).safeTransferFrom(msg.sender, offer.owner, _payForFines);

        //the borrower has paid off all the debt
        if (repaymentPhase.remainingInterest.add(repaymentPhase.remainingLoan).add(repaymentPhase.remainingFines) == 0) {
            executeLiquidity(_contractId);
        }
        uint256 historyId = createPaymentHistory(_contractId, msg.sender, offer.repaymentAsset, _payForLoan, _payForInterest, _payForFines);
        emit Repayment(historyId, _contractId, _contract.currentRepaymentPhase, offer.repaymentAsset, _payForLoan, _payForInterest, _payForFines);
    }

    /**
        * @dev create payment history function
        */

    function createPaymentHistory(
        uint256 _contractId,
        address _payerAddress,
        address _paymentToken,
        uint256 _payForLoan,
        uint256 _payForInterest,
        uint256 _payForFines
    )
    internal
    returns (uint256 _idx)
    {
        _idx = numberPaymentHistory;
        PaymentHistory storage payment = paymentHistories[_idx];
        payment.contractId = _contractId;
        payment.paymentToken = _paymentToken;
        payment.payerAddress = _payerAddress;
        payment.payForInterest = _payForInterest;
        payment.payForLoan = _payForLoan;
        payment.payForFines = _payForFines;
        payment.createAt = block.timestamp;

        ++numberPaymentHistory;
    }

    /**
       * @dev executeLiquidity is function used for asset liquidation
       * @param  _contractId is id contract
       */

    function executeLiquidity(uint256 _contractId)
    internal
    {
        Contract storage _contract = contracts[_contractId];
        Offer storage offer = offers[_contract.offerId];
        Collateral storage collateral = collaterals[_contract.collateralId];
        //get current status of repayment phase
        RepaymentPhase memory repaymentPhase = repaymentPhases[_contractId][_contract.currentRepaymentPhase];

        //the borrower has paid off all the debt
        if (repaymentPhase.remainingInterest.add(repaymentPhase.remainingLoan).add(repaymentPhase.remainingFines) == 0) {
            //transfer collateral asset back to collateral's owner
            if (collateral.collateralAddress != address(0)) {
                IERC20(collateral.collateralAddress).transfer(collateral.owner, collateral.amount);
            } else {
                payable(collateral.owner).transfer(collateral.amount);
            }
            emit Liquidity(collateral.owner, collateral.amount, 1);
        } else {
            //the borrower hasn't paid off all the debt
            if (collateral.collateralAddress != address(0)) { // transfer collateral to offer's owner
                IERC20(collateral.collateralAddress).transfer(offer.owner, collateral.amount);
            } else {
                payable(offer.owner).transfer(collateral.amount);
            }
            emit Liquidity(offer.owner, collateral.amount, 0);
        }

        //change status of contract, collateral, offer
        _contract.status = ContractStatus.COMPLETED;
        collateral.status = CollateralStatus.COMPLETED;
        offer.status = OfferStatus.COMPLETED;
    }

    /**
      * @dev createRepaymentPhase is the function which admin used to calculate the amount of debt remaining and the amount of interest
      * @param  _expiration is the time that the repayment phase will end
      */
    function createRepaymentPhase(
        uint256 _contractId,
        uint256 _remainingLoan,
        uint256 _remainingInterest,
        uint256 _remainingFines,
        uint256 _penalty,
        uint256 _expiration
    )
    public onlyOperator
    whenNotPaused
    {
        Contract storage _contract = contracts[_contractId];
        Offer memory offer = offers[_contract.offerId];
        require(_contract.status == ContractStatus.ACTIVE, 'Contract inactive');
        if (_penalty > penalty) {
            executeLiquidity(_contractId);
        }
        _contract.penalty = _penalty;
        RepaymentPhase storage repaymentPhase = repaymentPhases[_contractId][_contract.currentRepaymentPhase];
        repaymentPhase.remainingLoan = _remainingLoan;
        repaymentPhase.remainingInterest = _remainingInterest;
        repaymentPhase.remainingFines = _remainingFines;
        repaymentPhase.paidForInterest = 0;
        repaymentPhase.paidForLoan = 0;
        repaymentPhase.paidForFines = 0;
        repaymentPhase.expiration = _expiration;
    }

    /**
     * @dev liquidity is the function which admin used to execute contract liquidation
     * @param  _contractId is the id of contract
     */
    function liquidity(uint256 _contractId)
    public onlyOperator
    whenNotPaused {
        executeLiquidity(_contractId);
    }


    /**
    * @dev emergencyWithdraw is a function to be used only in emergencies
    * @param  _token is the address of withdrawal token
    */

    function emergencyWithdraw(address _token)
    public onlyOperator
    whenPaused {
        if (_token == address (0)) {
            coldWallet.transfer(address(this).balance);
        } else {
            IERC20(_token).transfer(coldWallet, IERC20(_tokenAddress).balanceOf(address(this)));
        }
    }
}
