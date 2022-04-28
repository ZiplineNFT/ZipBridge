// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.11;

import "solmate/tokens/ERC721.sol";
import {IConnextHandler} from "nxtp/interfaces/IConnextHandler.sol";
import {IExecutor} from "nxtp/interfaces/IExecutor.sol";
import "openzeppelin-contracts/contracts/utils/Create2.sol";
import "openzeppelin-contracts/contracts/utils/Address.sol";
import "ERC721X/interfaces/IERC721X.sol";
import "ERC721X/ERC721X.sol";

contract NFTYeeter is ERC721TokenReceiver {

    uint32 public immutable localDomain;
    address public immutable connext;
    address public owner;

    mapping(address => mapping(uint256 => DepositDetails)) deposits; // deposits[collection][tokenId] = depositor
    mapping(uint32 => address) trustedYeeters; // remote addresses of other yeeters, though ideally
                                               // we would want them all to have the same address. still, some may upgrade

    constructor(uint32 _localDomain, address _connext) {
        localDomain = _localDomain;
        connext = _connext;
        owner = msg.sender;
    }

    function setOwner(address newOwner) external {
        require(msg.sender == owner);
        owner = newOwner;
    }

    function setTrustedYeeter(uint32 chainId, address yeeter) external {
        require(msg.sender == owner);
        trustedYeeters[chainId] = yeeter;
    }

    // this is maintained on each "Home" chain where an NFT is originally locked
    // we don't need it on remote chains because:
    // - the ERC721X on the remote chain will have all the info we need to re-bridge the NFT to another chain
    // - you can't "unwrap" an NFT on a remote chain and that's what this is for
    struct DepositDetails {
        address depositor;
        bool bridged;
    }

    // this is used to mint new NFTs upon receipt on a "remote" chain
    // if this big payload makes bridging expensive, we should separate
    // the process of bridging a collection (name, symbol) from bridging
    // of tokens (tokenId, tokenUri)
    // specially once we add royalties
    //
    // buuuut... this would add a requirement that a collection *must* be bridged before any single items
    // can be bridged, which was a big value add
    //
    // it will all come down to how expensive bridging a single item + all the data for the collection is
    struct BridgedTokenDetails {
        uint16 originChainId;
        address originAddress;
        uint256 tokenId;
        address owner;
        string name;
        string symbol;
        string tokenURI;
    }

    function _calculateCreate2Address(uint32 chainId, address originAddress) internal view returns (address) {
        bytes32 salt = keccak(abi.encodePacked(originChainId, originAddress));
        bytes memory creationCode = type(ERC721X).creationCode;
        return Create2.computeAddress(salt, keccak256(creationCode));
    }

    function getLocalAddress(uint32 originChainId, address originAddress) external view returns (address) {
        // modify this method to return deterministic address according to create2
        return _calculateCreate2Address(originChainId, originAddress);
    }

    function _deployERC721X(uint32 chainId, address originAddress) internal view returns (ERC721X) {
        bytes32 salt = keccak(abi.encodePacked(originChainId, originAddress));
        bytes memory creationCode = type(ERC721X).creationCode;
        return ERC721X(Create2.deploy(0, salt, creationCode));
    }

    function withdraw(address collection, uint256 tokenId) external {
        require(ERC721(collection).ownerOf(tokenId) == address(this), "NFT Not Deposited");
        DepositDetails memory details = deposits[collection][tokenId];
        require(details.bridged == false, "NFT Currently Bridged");
        require(details.depositor == msg.sender, "Unauth");
        ERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
    }

    // function called by remote contract
    // this signature maximizes future flexibility & backwards compatibility
    function receiveAsset(bytes memory _payload) public {
        // only connext can call this
        require(msg.sender == connext, "NOT_CONNEXT");
        // check remote contract is trusted remote NFTYeeter
        uint32 remoteChainId = IExecutor(msg.sender).origin();
        address remoteCaller = IExecutor(msg.sender).originSender();
        require(trustedYeeters[remoteChainId] == remoteCaller, "UNAUTH");

        (BridgedTokenDetails memory details) = abi.decode(_payload, (BridgedTokenDetails));

        if (details.originChainId == localDomain) {
            // we're bridging this NFT *back* home
            DepositDetails storage depositDetails = deposits[details.originAddress][details.tokenId];

            // record new owner, may have changed on other chain
            depositDetails.depositor = details.owner;

            // record that the NFT is *back* and does not exist on other chains
            depositDetails.bridged = false; // enables withdrawal of native NFT

        } else {
            address localAddress = _calculateCreate2Address(details.originChainId, details.originAddress);
            if (!Address.isContract(localAddress)) { // this check will change after create2
                // local XERC721 contract exists, we just need to mint
                ERC721X nft = ERC721X(localAddress[details.originChainId][details.originAddress]);
                nft.mint(details.owner, details.tokenId, details.tokenURI);
            } else {
                // deploy new ERC721 contract
                // this will also change w/ create2
                ERC721X nft = _deployERC721X(details.originChainId, details.originAddress);
                nft.mint(details.owner, details.tokenId, details.tokenURI);
            }
        }


    }

    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        deposits[msg.sender][tokenId] = DepositDetails({depositor: from, bridged: false });
        return ERC721TokenReceiver.onERC721Received.selector;
    }
}
