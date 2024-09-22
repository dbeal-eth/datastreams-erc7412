// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {IERC7412} from "./interfaces/IERC7412.sol";
import {IFeeManager, Common} from "./interfaces/IFeeManager.sol";
import {IVerifierProxy} from "./interfaces/IVerifierProxy.sol";
import {IRewardManager} from "@chainlink/contracts/src/v0.8/llo-feeds/interfaces/IRewardManager.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/contracts/interfaces/IERC20.sol";
import {Withdraw} from "./utils/Withdraw.sol";

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES HARDCODED VALUES FOR CLARITY.
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 */
contract DataStreamsERC7412Compatible is IERC7412, Withdraw {
    struct BasicReport {
        bytes32 feedId; // The feed ID the report has data for
        uint32 validFromTimestamp; // Earliest timestamp for which price is applicable
        uint32 observationsTimestamp; // Latest timestamp for which price is applicable
        uint192 nativeFee; // Base cost to validate a transaction using the report, denominated in the chain’s native token (WETH/ETH)
        uint192 linkFee; // Base cost to validate a transaction using the report, denominated in LINK
        uint32 expiresAt; // Latest timestamp where the report can be verified on-chain
        int192 price; // DON consensus median price, carried to 8 decimal places
    }

    /**
     * @notice The Chainlink Verifier Contract
     * This contract verifies the signature from the DON to cryptographically guarantee that the report has not been altered
     * from the time that the DON reached consensus to the point where you use the data in your application.
     */
    IVerifierProxy immutable verifier;

    string public constant STRING_DATASTREAMS_FEEDLABEL = "feedIDs";
    string public constant STRING_DATASTREAMS_QUERYLABEL = "timestamp";

    mapping(bytes32 => uint32) public s_latestPriceTimestamp;
		mapping(bytes32 => mapping(uint32 => int192)) public s_priceSnapshots;

    event PriceUpdate(int192 indexed price, bytes32 indexed feedId);

    /**
     * @dev Value doesn't fit in an uint of `bits` size.
     */
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    constructor(address _verifier) {
        verifier = IVerifierProxy(_verifier);
    }

    receive() external payable {}

    function oracleId() external pure override returns (bytes32) {
        return "CHAINLINK_DATA_STREAMS";
    }

    /**
     * @notice Retrieves the latest price for the given feedId. If the price is too stale, an OracleDataRequired error is emitted.
     * @param feedId - Stream ID which can be found at https://docs.chain.link/data-streams/stream-ids
     */
    function getLatestPrice(
        bytes32 feedId,
        uint32 stalenessTolerance
    ) public returns (int192) {
        uint32 latestPriceTimestamp = s_latestPriceTimestamp[feedId];
        uint32 considerStaleAfter = latestPriceTimestamp +
            stalenessTolerance;

        if (
            considerStaleAfter > toUint32(block.timestamp)
        ) {
            return s_priceSnapshots[feedId][latestPriceTimestamp];
        }

        bytes memory oracleQuery = abi.encode(
            STRING_DATASTREAMS_FEEDLABEL,
            feedId,
            STRING_DATASTREAMS_QUERYLABEL,
            block.timestamp,
            ""
        );

        // Fees can be paid in either LINK (i_linkAddress()) or native coin ERC20-wrapped version (i_nativeAddress())
        IFeeManager feeManager = IFeeManager(address(verifier.s_feeManager()));
        address feeTokenAddress = feeManager.i_linkAddress();
        (Common.Asset memory fee, , ) = feeManager.getFeeAndReward(
            address(this),
            "",
            feeTokenAddress
        );

        revert IERC7412.OracleDataRequired(address(this), oracleQuery, fee.amount);
    }

    /**
     * @notice Retrieves the price for the given feedId at a given timestamp. If a matching price update is not found, an OracleDataRequired error is emitted.
     * @param feedId - Stream ID which can be found at https://docs.chain.link/data-streams/stream-ids
		 * @param forTimestamp - The timestamp in the past that should be retrieved
     */
    function getPriceForTimestamp(
        bytes32 feedId,
        uint32 forTimestamp
    ) public returns (int192) {
        int192 price = s_priceSnapshots[feedId][forTimestamp];

				// consider the prices to be populated if its non-0
				// if a price is actually reported as 0, its probably either a price feed nobody would ever care about, or its an error.
        if (
					price != 0
        ) {
						// if we are calling this function and it is not the currently recognized latest price,
						// we can delete the price and likely save big gas in most cases
						if (s_latestPriceTimestamp[feedId] != forTimestamp) {
								s_priceSnapshots[feedId][forTimestamp] = 0;
						}
            return price;
        }

        bytes memory oracleQuery = abi.encode(
            STRING_DATASTREAMS_FEEDLABEL,
            feedId,
            STRING_DATASTREAMS_QUERYLABEL,
            forTimestamp,
            ""
        );

        // Fees can be paid in either LINK (i_linkAddress()) or native coin ERC20-wrapped version (i_nativeAddress())
        IFeeManager feeManager = IFeeManager(address(verifier.s_feeManager()));
        address feeTokenAddress = feeManager.i_linkAddress();
        (Common.Asset memory fee, , ) = feeManager.getFeeAndReward(
            address(this),
            "",
            feeTokenAddress
        );

        revert IERC7412.OracleDataRequired(address(this), oracleQuery, fee.amount);
    }

    function fulfillOracleQuery(
        bytes calldata signedOffchainData
    ) external payable override {
        // Decode incoming signedOffchainData
        (bytes memory signedReport, ) = abi.decode(
            signedOffchainData,
            (bytes, bytes)
        );

        (, bytes memory reportData) = abi.decode(
            signedReport,
            (bytes32[3], bytes)
        );

        // Handle billing
        IFeeManager feeManager = IFeeManager(address(verifier.s_feeManager()));
        IRewardManager rewardManager = IRewardManager(
            address(feeManager.i_rewardManager())
        );

        address feeTokenAddress = feeManager.i_linkAddress();
        (Common.Asset memory fee, , ) = feeManager.getFeeAndReward(
            address(this),
            reportData,
            feeTokenAddress
        );

        if (IERC20(feeTokenAddress).balanceOf(address(this)) < fee.amount) {
            revert IERC7412.FeeRequired(fee.amount);
        } else {
            IERC20(feeTokenAddress).approve(address(rewardManager), fee.amount);
        }

        // Verify the report
        bytes memory verifiedReportData = verifier.verify(
            signedReport,
            abi.encode(feeTokenAddress)
        );

        // Decode verified report data into BasicReport struct
        BasicReport memory verifiedReport = abi.decode(
            verifiedReportData,
            (BasicReport)
        );

				s_priceSnapshots[verifiedReport.feedId][verifiedReport.observationsTimestamp] = verifiedReport.price;

				if (s_latestPriceTimestamp[verifiedReport.feedId] < verifiedReport.observationsTimestamp) {
						s_priceSnapshots[verifiedReport.feedId][s_latestPriceTimestamp[verifiedReport.feedId]] = 0;
						s_latestPriceTimestamp[verifiedReport.feedId] = verifiedReport.observationsTimestamp;
				}

        // Log price from report
        emit PriceUpdate(verifiedReport.price, verifiedReport.feedId);
    }

    /**
     * OpenZeppelin Contracts (last updated v5.0.0) (utils/math/SafeCast.sol)
     *
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        if (value > type(uint32).max) {
            revert SafeCastOverflowedUintDowncast(32, value);
        }
        return uint32(value);
    }
}
