// SPDX-License-Identifier: Apache 2.0
pragma solidity 0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20PresetMinterPauser} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {
    RootERC20BridgeFlowRate,
    IRootERC20BridgeFlowRateEvents,
    IRootERC20BridgeFlowRateErrors,
    IRootERC20Bridge
} from "../../../../src/root/flowrate/RootERC20BridgeFlowRate.sol";
import {
    IRootERC20BridgeEvents,
    IRootERC20BridgeErrors
} from "../../../../src/root/RootERC20Bridge.sol";
import {FlowRateWithdrawalQueue} from "../../../../src/root/flowrate/FlowRateWithdrawalQueue.sol";
import {MockAxelarGateway} from "../../../../src/test/root/MockAxelarGateway.sol";
import {MockAxelarGasService} from "../../../../src/test/root/MockAxelarGasService.sol";
import {MockAdaptor} from "../../../../src/test/root/MockAdaptor.sol";
import {Utils} from "../../../utils.t.sol";
import {WETH} from "../../../../src/test/root/WETH.sol";

contract RootERC20BridgeFlowRateUnitTest is
    Test,
    IRootERC20BridgeFlowRateEvents,
    IRootERC20BridgeFlowRateErrors,
    IRootERC20BridgeEvents,
    IRootERC20BridgeErrors,
    Utils
{
    address constant CHILD_BRIDGE = address(3);
    address constant CHILD_BRIDGE_ADAPTOR = address(4);
    string CHILD_BRIDGE_ADAPTOR_STRING = Strings.toHexString(CHILD_BRIDGE_ADAPTOR);
    string constant CHILD_CHAIN_NAME = "test";
    address constant IMX_TOKEN = address(0xccc);
    address constant NATIVE_ETH = address(0xeee);
    address constant WRAPPED_ETH = address(0xddd);
    uint256 constant mapTokenFee = 300;
    uint256 constant depositFee = 200;
    uint256 constant UNLIMITED_IMX_DEPOSITS = 0;

    uint256 constant CAPACITY = 1000000;
    uint256 constant REFILL_RATE = 277; // Refill each hour.
    uint256 constant LARGE = 100000;

    uint256 constant CAPACITY_ETH = 1000000 ether;
    uint256 constant REFILL_RATE_ETH = 277 ether; // Refill each hour.
    uint256 constant LARGE_ETH = 100000 ether;

    uint256 constant CHARLIE_REMAINDER = 17;
    uint256 constant CHARLIE_REMAINDER_ETH = 17 ether;

    uint256 constant BRIDGED_VALUE = CAPACITY * 100;
    uint256 constant BRIDGED_VALUE_ETH = CAPACITY_ETH * 100;

    bytes32 internal constant RATE_CONTROL_ROLE = keccak256("RATE");

    address alice;
    address bob;
    address charlie;

    address rateAdmin;
    address pauseAdmin;
    address nonAdmin;
    uint256 withdrawalDelay;

    ERC20PresetMinterPauser public token;
    ERC20PresetMinterPauser public imxToken;
    RootERC20BridgeFlowRate public rootBridgeFlowRate;
    MockAdaptor public mockAxelarAdaptor;
    MockAxelarGateway public mockAxelarGateway;
    MockAxelarGasService public axelarGasService;

    function setUp() public {
        token = new ERC20PresetMinterPauser("Test", "TST");
        token.mint(address(this), 100 ether);
        deployCodeTo("ERC20PresetMinterPauser.sol", abi.encode("ImmutableX", "IMX"), IMX_TOKEN);
        imxToken = ERC20PresetMinterPauser(IMX_TOKEN);
        imxToken.mint(address(this), 100 ether);

        deployCodeTo("WETH.sol", abi.encode("Wrapped ETH", "WETH"), WRAPPED_ETH);

        rateAdmin = makeAddr("rateadmin");
        pauseAdmin = makeAddr("pauseadmin");
        nonAdmin = makeAddr("nonadmin");

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        rootBridgeFlowRate = new RootERC20BridgeFlowRate();
        mockAxelarGateway = new MockAxelarGateway();
        axelarGasService = new MockAxelarGasService();

        mockAxelarAdaptor = new MockAdaptor();

        IRootERC20Bridge.InitializationRoles memory roles = IRootERC20Bridge.InitializationRoles({
            defaultAdmin: address(this),
            pauser: pauseAdmin,
            unpauser: pauseAdmin,
            variableManager: address(this),
            adaptorManager: address(this)
        });

        // The specific ERC20 token template does not matter for these unit tests
        rootBridgeFlowRate.initialize(
            roles,
            address(mockAxelarAdaptor),
            CHILD_BRIDGE,
            CHILD_BRIDGE_ADAPTOR_STRING,
            address(token),
            IMX_TOKEN,
            WRAPPED_ETH,
            CHILD_CHAIN_NAME,
            UNLIMITED_IMX_DEPOSITS,
            rateAdmin
        );

        withdrawalDelay = rootBridgeFlowRate.withdrawalDelay();
    }

    function activateWithdrawalQueue() internal {
        vm.prank(rateAdmin);
        rootBridgeFlowRate.activateWithdrawalQueue();
    }

     function configureFlowRate() internal {
        vm.startPrank(rateAdmin);
        rootBridgeFlowRate.setRateControlThreshold(address(token), CAPACITY, REFILL_RATE, LARGE);
        rootBridgeFlowRate.setRateControlThreshold(NATIVE_ETH, CAPACITY_ETH, REFILL_RATE_ETH, LARGE_ETH);
        vm.stopPrank();
    }

    /**
     * INITIALIZE
     */

    function test_InitializeBridgeFlowRate() public {
        assertEq(address(rootBridgeFlowRate.rootBridgeAdaptor()), address(mockAxelarAdaptor), "bridgeAdaptor not set");
        assertEq(rootBridgeFlowRate.childERC20Bridge(), CHILD_BRIDGE, "childERC20Bridge not set");
        assertEq(rootBridgeFlowRate.childTokenTemplate(), address(token), "childTokenTemplate not set");
        assert(Strings.equal(rootBridgeFlowRate.childChain(), CHILD_CHAIN_NAME));
        assert(Strings.equal(CHILD_BRIDGE_ADAPTOR_STRING, rootBridgeFlowRate.childBridgeAdaptor()));
        assertEq(address(token), rootBridgeFlowRate.childTokenTemplate(), "childTokenTemplate not set");
        assertEq(rootBridgeFlowRate.rootIMXToken(), IMX_TOKEN, "rootIMXToken not set");
        assertEq(rootBridgeFlowRate.rootWETHToken(), WRAPPED_ETH, "rootWETHToken not set");
    }

    function test_RevertIfInitializedTwice() public {
        IRootERC20Bridge.InitializationRoles memory roles = IRootERC20Bridge.InitializationRoles({
            defaultAdmin: address(this),
            pauser: address(this),
            unpauser: address(this),
            variableManager: address(this),
            adaptorManager: address(this)
        });

        vm.expectRevert("Initializable: contract is already initialized");
        rootBridgeFlowRate.initialize(
            roles,
            address(mockAxelarAdaptor),
            CHILD_BRIDGE,
            CHILD_BRIDGE_ADAPTOR_STRING,
            address(token),
            IMX_TOKEN,
            WRAPPED_ETH,
            CHILD_CHAIN_NAME,
            UNLIMITED_IMX_DEPOSITS,
            address(this)
        );
    }

    function test_RevertIfRootBridgeInitializedDirectly() public {
        IRootERC20Bridge.InitializationRoles memory roles = IRootERC20Bridge.InitializationRoles({
            defaultAdmin: address(this),
            pauser: address(this),
            unpauser: address(this),
            variableManager: address(this),
            adaptorManager: address(this)
        });

        vm.expectRevert(WrongInitializer.selector);
        rootBridgeFlowRate.initialize(
            roles,
            address(mockAxelarAdaptor),
            CHILD_BRIDGE,
            CHILD_BRIDGE_ADAPTOR_STRING,
            address(token),
            IMX_TOKEN,
            WRAPPED_ETH,
            CHILD_CHAIN_NAME,
            UNLIMITED_IMX_DEPOSITS
        );
    }

    /**
     * RATE ROLE ACTIONS
     */

    function testActivateWithdrawalQueue() public {
        vm.prank(rateAdmin);
        rootBridgeFlowRate.activateWithdrawalQueue();
        assertTrue(rootBridgeFlowRate.withdrawalQueueActivated());
    }

    function testActivateWithdrawalQueueBadAuth() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        rootBridgeFlowRate.activateWithdrawalQueue();
    }

    function testDeactivateWithdrawalQueue() public {
        activateWithdrawalQueue();
        vm.prank(rateAdmin);
        rootBridgeFlowRate.deactivateWithdrawalQueue();
        assertFalse(rootBridgeFlowRate.withdrawalQueueActivated());
    }

    function testDeactivateWithdrawalQueueBadAuth() public {
        activateWithdrawalQueue();
        vm.prank(nonAdmin);
        vm.expectRevert();
        rootBridgeFlowRate.deactivateWithdrawalQueue();
    }

    function testSetWithdrawalDelay() public {
        uint256 delay = 1000;
        vm.prank(rateAdmin);
        rootBridgeFlowRate.setWithdrawalDelay(delay);
        assertEq(rootBridgeFlowRate.withdrawalDelay(), delay);
    }

    function testSetWithdrawalDelayBadAuth() public {
        uint256 delay = 1000;
        vm.prank(nonAdmin);
        vm.expectRevert();
        rootBridgeFlowRate.setWithdrawalDelay(delay);
    }

    function testSetRateControlThreshold() public {
        vm.prank(rateAdmin);
        vm.expectEmit(true, true, false, true);
        emit RateControlThresholdSet(address(token), CAPACITY, REFILL_RATE, LARGE);
        rootBridgeFlowRate.setRateControlThreshold(address(token), CAPACITY, REFILL_RATE, LARGE);
        assertEq(rootBridgeFlowRate.largeTransferThresholds(address(token)), LARGE);
        uint256 capacity; 
        uint256 refillRate;
        (capacity, , , refillRate) = rootBridgeFlowRate.flowRateBuckets(address(token));
        assertEq(capacity, CAPACITY, "Capacity");
        assertEq(refillRate, REFILL_RATE, "Refill rate");
    }

    function testSetRateControlThresholdBadAuth() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        rootBridgeFlowRate.setRateControlThreshold(address(token), CAPACITY, REFILL_RATE, LARGE);
    }

    /**
     * FLOW RATE WITHDRAW
     */

    function testWithdrawalUnconfiguredToken() public {
        
        // Need to first map the token.
        rootBridgeFlowRate.mapToken(token);
        // And give the bridge some tokens
        token.transfer(address(rootBridgeFlowRate), BRIDGED_VALUE);

        uint256 amount = 5;

        uint256 now1 = 100;
        vm.warp(now1);

        bytes memory data = abi.encode(WITHDRAW_SIG, token, alice, bob, amount);

        vm.prank(address(mockAxelarAdaptor));

        vm.expectEmit(true, true, true, true, address(rootBridgeFlowRate));
        emit QueuedWithdrawal(address(token), alice, bob, amount, false, true, false);
        rootBridgeFlowRate.onMessageReceive(CHILD_CHAIN_NAME, CHILD_BRIDGE_ADAPTOR_STRING, data);

        //assertEq(token.balanceOf(address(charlie)), CHARLIE_REMAINDER, "charlie");
        assertEq(token.balanceOf(address(alice)), 0, "alice");
        assertEq(token.balanceOf(address(bob)), 0, "bob");
        assertEq(token.balanceOf(address(rootBridgeFlowRate)), BRIDGED_VALUE, "rootBridgeFlowRate");

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;
        FlowRateWithdrawalQueue.PendingWithdrawal[] memory pending = rootBridgeFlowRate.getPendingWithdrawals(bob, indices);
        assertEq(pending.length, 1, "Pending withdrawal length");
        assertEq(pending[0].withdrawer, address(alice), "Withdrawer");
        assertEq(pending[0].token, address(token), "Token");
        assertEq(pending[0].amount, amount, "Amount");
        assertEq(pending[0].timestamp, now1, "Timestamp");
    }

    function testWithdrawalLargeWithdrawal() public {
        configureFlowRate();
        // Need to first map the token.
        rootBridgeFlowRate.mapToken(token);
        // And give the bridge some tokens
        token.transfer(address(rootBridgeFlowRate), BRIDGED_VALUE);

        uint256 amount = LARGE;

        uint256 now1 = 100;
        vm.warp(now1);

        bytes memory data = abi.encode(WITHDRAW_SIG, token, alice, bob, amount);

        vm.prank(address(mockAxelarAdaptor));

        vm.expectEmit(true, true, true, true, address(rootBridgeFlowRate));
        emit QueuedWithdrawal(address(token), alice, bob, amount, true, false, false);
        rootBridgeFlowRate.onMessageReceive(CHILD_CHAIN_NAME, CHILD_BRIDGE_ADAPTOR_STRING, data);

        assertEq(token.balanceOf(address(alice)), 0, "alice");
        assertEq(token.balanceOf(address(bob)), 0, "bob");
        assertEq(token.balanceOf(address(rootBridgeFlowRate)), BRIDGED_VALUE, "rootBridgeFlowRate");

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;
        FlowRateWithdrawalQueue.PendingWithdrawal[] memory pending = rootBridgeFlowRate.getPendingWithdrawals(bob, indices);
        assertEq(pending.length, 1, "Pending withdrawal length");
        assertEq(pending[0].withdrawer, address(alice), "Withdrawer");
        assertEq(pending[0].token, address(token), "Token");
        assertEq(pending[0].amount, amount, "Amount");
        assertEq(pending[0].timestamp, now1, "Timestamp");
    }

    function testHighFlowRate() public {
        vm.warp(100);
        configureFlowRate();
        // Need to first map the token.
        rootBridgeFlowRate.mapToken(token);
        // And give the bridge some tokens
        token.transfer(address(rootBridgeFlowRate), BRIDGED_VALUE);

        uint256 amount = LARGE - 1;
        uint256 timesBeforeHighFlowRate = CAPACITY / amount;

        bytes memory data = abi.encode(WITHDRAW_SIG, token, alice, bob, amount);

        address childERC20Token = rootBridgeFlowRate.rootTokenToChildToken(address(token));
        uint256 total;
        for (uint256 i = 0; i < timesBeforeHighFlowRate; i++) {
            vm.prank(address(mockAxelarAdaptor));
            vm.expectEmit(true, true, true, true, address(rootBridgeFlowRate));
            emit RootChainERC20Withdraw(
                address(token),
                childERC20Token,
                alice,
                bob,
                amount
            );
            rootBridgeFlowRate.onMessageReceive(CHILD_CHAIN_NAME, CHILD_BRIDGE_ADAPTOR_STRING, data);
            assertFalse(rootBridgeFlowRate.withdrawalQueueActivated(), "queue activated!");
            total += amount;
            assertEq(token.balanceOf(address(bob)), total, "bob");
        }
        assertFalse(rootBridgeFlowRate.withdrawalQueueActivated(), "queue activated!");

        vm.prank(address(mockAxelarAdaptor));
        vm.expectEmit(true, true, true, true, address(rootBridgeFlowRate));
        emit QueuedWithdrawal(address(token), alice, bob, amount, false, false, true);
        rootBridgeFlowRate.onMessageReceive(CHILD_CHAIN_NAME, CHILD_BRIDGE_ADAPTOR_STRING, data);
        assertTrue(rootBridgeFlowRate.withdrawalQueueActivated(), "queue not activated!");
        assertEq(token.balanceOf(address(bob)), total, "bob");
    }

    //  function testWithdrawalWhenPaused() public {

    //      // Need to first map the token.
    //     rootBridgeFlowRate.mapToken(token);
    //     // And give the bridge some tokens
    //     token.transfer(address(rootBridgeFlowRate), 100 ether);

    //     configureFlowRate();

    //     uint256 amount = 5 ether;

    //     // Fake a crosschain transfer from the child chain to the root chain.
    //     bytes memory data = abi.encode(WITHDRAW_SIG, token, address(this), address(this), amount);


    //     vm.prank(address(mockAxelarAdaptor));
    //     rootBridgeFlowRate.onMessageReceive(CHILD_CHAIN_NAME, CHILD_BRIDGE_ADAPTOR_STRING, data);
    // }


    /**
     * PROCESS QUEUED WITHDRAWALS
     */

}
