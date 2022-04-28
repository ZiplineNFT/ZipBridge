// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.11;

import "forge-std/Test.sol";
import "../src/NFTYeeter.sol";
import {IConnextHandler} from "nxtp/interfaces/IConnextHandler.sol";
import "solmate/tokens/ERC721.sol";
import "ERC721X/ERC721X.sol";
import "forge-std/console.sol";
import "forge-std/console2.sol";

contract ContractTest is Test {

    NFTYeeter yeeter;
    NFTYeeter remoteYeeter;
    ERC721X localNFT;
    address public alice = address(0x1212121212121212);
    address public bob = address(0xbb);
    address public charlie = address(0xcc);
    address public connext = address(0xce);
    address remoteContract = address(0x1111);
    address transactingAssetId = address(0);
    uint32 localDomain = uint32(1);
    uint32 remoteDomain = uint32(2);

    function setUp() public {
        yeeter = new NFTYeeter(localDomain, connext, transactingAssetId);
        remoteYeeter = new NFTYeeter(remoteDomain, connext, transactingAssetId);
        yeeter.setTrustedYeeter(remoteDomain, address(remoteYeeter));
        localNFT = new ERC721X("TestMonkeys", "TST", address(0), localDomain);
        localNFT.mint(alice, 0, "testURI");
    }

    function testYeeterAcceptsDeposits() public {
        vm.prank(alice);
        localNFT.safeTransferFrom(alice, address(yeeter), 0);
        assertEq(localNFT.ownerOf(0), address(yeeter));
        (address depositor, bool bridged) = yeeter.deposits(address(localNFT), 0);
        assertEq(depositor, alice);
        assertTrue(!bridged);
    }

    function testYeeterWillBridge() public {
        vm.startPrank(alice);
        localNFT.safeTransferFrom(alice, address(yeeter), 0);
        vm.mockCall(connext, abi.encodePacked(IConnextHandler.xcall.selector), abi.encode(0));
        yeeter.bridgeToken(address(localNFT), 0, alice, remoteDomain);
        (address depositor, bool bridged) = yeeter.deposits(address(localNFT), 0);
        assertEq(depositor, alice);
        assertTrue(bridged);
    }

}