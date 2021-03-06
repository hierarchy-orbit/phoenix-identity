pragma solidity ^0.5.0;

import "./zeppelin/ownership/Ownable.sol";
import "./zeppelin/math/SafeMath.sol";

import "./interfaces/PhoenixInterface.sol";
import "./interfaces/PhoenixIdentityResolverInterface.sol";
import "./interfaces/PhoenixIdentityViaInterface.sol";
import "./interfaces/IdentityRegistryInterface.sol";
import "./interfaces/ClientPhoenixAuthenticationInterface.sol";

contract PhoenixIdentity is Ownable {
    using SafeMath for uint;

    // mapping of PHNX_ID to Phoenix token deposits
    mapping (uint => uint) public deposits;
    // mapping from PHNX_ID to resolver to allowance
    mapping (uint => mapping (address => uint)) public resolverAllowances;

    // SC variables
    address public identityRegistryAddress;
    IdentityRegistryInterface private identityRegistry;
    address public phoenixTokenAddress;
    PhoenixInterface private phoenixToken;
    address public clientPhoenixAuthenticationAddress;
    ClientPhoenixAuthenticationInterface private clientPhoenixAuthentication;

    // signature variables
    uint public signatureTimeout = 1 days;
    mapping (uint => uint) public signatureNonce;

    constructor (address _identityRegistryAddress, address _phoenixTokenAddress) public {
        setAddresses(_identityRegistryAddress, _phoenixTokenAddress);
    }

    // enforces that a particular PHNX_ID exists
    modifier identityExists(uint PHNX_ID, bool check) {
        require(identityRegistry.identityExists(PHNX_ID) == check, "The PHNX_ID does not exist.");
        _;
    }

    // enforces signature timeouts
    modifier ensureSignatureTimeValid(uint timestamp) {
        require(
            // solium-disable-next-line security/no-block-members
            block.timestamp >= timestamp && block.timestamp < timestamp + signatureTimeout, "Timestamp is not valid."
        );
        _;
    }


    // set the phoenix token and identity registry addresses
    function setAddresses(address _identityRegistryAddress, address _phoenixTokenAddress) public onlyOwner {
        identityRegistryAddress = _identityRegistryAddress;
        identityRegistry = IdentityRegistryInterface(identityRegistryAddress);

        phoenixTokenAddress = _phoenixTokenAddress;
        phoenixToken = PhoenixInterface(phoenixTokenAddress);
    }

    function setClientPhoenixAuthenticationAddress(address _clientPhoenixAuthenticationAddress) public onlyOwner {
        clientPhoenixAuthenticationAddress = _clientPhoenixAuthenticationAddress;
        clientPhoenixAuthentication = ClientPhoenixAuthenticationInterface(clientPhoenixAuthenticationAddress);
    }

    // wrap createIdentityDelegated and initialize the client phoenixAuthentication resolver
    function createIdentityDelegated(
        address recoveryAddress, address associatedAddress, address[] memory providers, string memory casedPhoenixId,
        uint8 v, bytes32 r, bytes32 s, uint timestamp
    )
        public returns (uint PHNX_ID)
    {
        address[] memory _providers = new address[](providers.length + 1);
        _providers[0] = address(this);
        for (uint i; i < providers.length; i++) {
            _providers[i + 1] = providers[i];
        }

        uint _PHNX_ID = identityRegistry.createIdentityDelegated(
            recoveryAddress, associatedAddress, _providers, new address[](0), v, r, s, timestamp
        );

        _addResolver(_PHNX_ID, clientPhoenixAuthenticationAddress, true, 0, abi.encode(associatedAddress, casedPhoenixId));

        return _PHNX_ID;
    }

    // permission addProvidersFor by signature
    function addProvidersFor(
        address approvingAddress, address[] memory providers, uint8 v, bytes32 r, bytes32 s, uint timestamp
    )
        public ensureSignatureTimeValid(timestamp)
    {
        uint PHNX_ID = identityRegistry.getPHNX_ID(approvingAddress);
        require(
            identityRegistry.isSigned(
                approvingAddress,
                keccak256(
                    abi.encodePacked(
                        byte(0x19), byte(0), address(this),
                        "I authorize that these Providers be added to my Identity.",
                        PHNX_ID, providers, timestamp
                    )
                ),
                v, r, s
            ),
            "Permission denied."
        );

        identityRegistry.addProvidersFor(PHNX_ID, providers);
    }

    // permission removeProvidersFor by signature
    function removeProvidersFor(
        address approvingAddress, address[] memory providers, uint8 v, bytes32 r, bytes32 s, uint timestamp
    )
        public ensureSignatureTimeValid(timestamp)
    {
        uint PHNX_ID = identityRegistry.getPHNX_ID(approvingAddress);
        require(
            identityRegistry.isSigned(
                approvingAddress,
                keccak256(
                    abi.encodePacked(
                        byte(0x19), byte(0), address(this),
                        "I authorize that these Providers be removed from my Identity.",
                        PHNX_ID, providers, timestamp
                    )
                ),
                v, r, s
            ),
            "Permission denied."
        );

        identityRegistry.removeProvidersFor(PHNX_ID, providers);
    }

    // permissioned addProvidersFor and removeProvidersFor by signature
    function upgradeProvidersFor(
        address approvingAddress, address[] memory newProviders, address[] memory oldProviders,
        uint8[2] memory v, bytes32[2] memory r, bytes32[2] memory s, uint[2] memory timestamp
    )
        public
    {
        addProvidersFor(approvingAddress, newProviders, v[0], r[0], s[0], timestamp[0]);
        removeProvidersFor(approvingAddress, oldProviders, v[1], r[1], s[1], timestamp[1]);
        uint PHNX_ID = identityRegistry.getPHNX_ID(approvingAddress);
        emit PhoenixIdentityProvidersUpgraded(PHNX_ID, newProviders, oldProviders, approvingAddress);
    }

    // permission adding a resolver for identity of msg.sender
    function addResolver(address resolver, bool isPhoenixIdentity, uint withdrawAllowance, bytes memory extraData) public {
        _addResolver(identityRegistry.getPHNX_ID(msg.sender), resolver, isPhoenixIdentity, withdrawAllowance, extraData);
    }

    // permission adding a resolver for identity passed by a provider
    function addResolverAsProvider(
        uint PHNX_ID, address resolver, bool isPhoenixIdentity, uint withdrawAllowance, bytes memory extraData
    )
        public
    {
        require(identityRegistry.isProviderFor(PHNX_ID, msg.sender), "The msg.sender is not a Provider for the passed PHNX_ID");
        _addResolver(PHNX_ID, resolver, isPhoenixIdentity, withdrawAllowance, extraData);
    }

    // permission addResolversFor by signature
    function addResolverFor(
        address approvingAddress, address resolver, bool isPhoenixIdentity, uint withdrawAllowance, bytes memory extraData,
        uint8 v, bytes32 r, bytes32 s, uint timestamp
    )
        public
    {
        uint PHNX_ID = identityRegistry.getPHNX_ID(approvingAddress);

        validateAddResolverForSignature(
            approvingAddress, PHNX_ID, resolver, isPhoenixIdentity, withdrawAllowance, extraData, v, r, s, timestamp
        );

        _addResolver(PHNX_ID, resolver, isPhoenixIdentity, withdrawAllowance, extraData);
    }

    function validateAddResolverForSignature(
        address approvingAddress, uint PHNX_ID,
        address resolver, bool isPhoenixIdentity, uint withdrawAllowance, bytes memory extraData,
        uint8 v, bytes32 r, bytes32 s, uint timestamp
    )
        private view ensureSignatureTimeValid(timestamp)
    {
        require(
            identityRegistry.isSigned(
                approvingAddress,
                keccak256(
                    abi.encodePacked(
                        byte(0x19), byte(0), address(this),
                        "I authorize that this resolver be added to my Identity.",
                        PHNX_ID, resolver, isPhoenixIdentity, withdrawAllowance, extraData, timestamp
                    )
                ),
                v, r, s
            ),
            "Permission denied."
        );
    }

    // common logic for adding resolvers
    function _addResolver(uint PHNX_ID, address resolver, bool isPhoenixIdentity, uint withdrawAllowance, bytes memory extraData)
        private
    {
        require(!identityRegistry.isResolverFor(PHNX_ID, resolver), "Identity has already set this resolver.");

        address[] memory resolvers = new address[](1);
        resolvers[0] = resolver;
        identityRegistry.addResolversFor(PHNX_ID, resolvers);

        if (isPhoenixIdentity) {
            resolverAllowances[PHNX_ID][resolver] = withdrawAllowance;
            PhoenixIdentityResolverInterface phoenixIdentityResolver = PhoenixIdentityResolverInterface(resolver);
            if (phoenixIdentityResolver.callOnAddition())
                require(phoenixIdentityResolver.onAddition(PHNX_ID, withdrawAllowance, extraData), "Sign up failure.");
            emit PhoenixIdentityResolverAdded(PHNX_ID, resolver, withdrawAllowance);
        }
    }

    // permission changing resolver allowances for identity of msg.sender
    function changeResolverAllowances(address[] memory resolvers, uint[] memory withdrawAllowances) public {
        changeResolverAllowances(identityRegistry.getPHNX_ID(msg.sender), resolvers, withdrawAllowances);
    }

    // change resolver allowances delegated
    function changeResolverAllowancesDelegated(
        address approvingAddress, address[] memory resolvers, uint[] memory withdrawAllowances,
        uint8 v, bytes32 r, bytes32 s
    )
        public
    {
        uint PHNX_ID = identityRegistry.getPHNX_ID(approvingAddress);

        uint nonce = signatureNonce[PHNX_ID]++;
        require(
            identityRegistry.isSigned(
                approvingAddress,
                keccak256(
                    abi.encodePacked(
                        byte(0x19), byte(0), address(this),
                        "I authorize this change in Resolver allowances.",
                        PHNX_ID, resolvers, withdrawAllowances, nonce
                    )
                ),
                v, r, s
            ),
            "Permission denied."
        );

        changeResolverAllowances(PHNX_ID, resolvers, withdrawAllowances);
    }

    // common logic to change resolver allowances
    function changeResolverAllowances(uint PHNX_ID, address[] memory resolvers, uint[] memory withdrawAllowances) private {
        require(resolvers.length == withdrawAllowances.length, "Malformed inputs.");

        for (uint i; i < resolvers.length; i++) {
            require(identityRegistry.isResolverFor(PHNX_ID, resolvers[i]), "Identity has not set this resolver.");
            resolverAllowances[PHNX_ID][resolvers[i]] = withdrawAllowances[i];
            emit PhoenixIdentityResolverAllowanceChanged(PHNX_ID, resolvers[i], withdrawAllowances[i]);
        }
    }

    // permission removing a resolver for identity of msg.sender
    function removeResolver(address resolver, bool isPhoenixIdentity, bytes memory extraData) public {
        removeResolver(identityRegistry.getPHNX_ID(msg.sender), resolver, isPhoenixIdentity, extraData);
    }

    // permission removeResolverFor by signature
    function removeResolverFor(
        address approvingAddress, address resolver, bool isPhoenixIdentity, bytes memory extraData,
        uint8 v, bytes32 r, bytes32 s, uint timestamp
    )
        public ensureSignatureTimeValid(timestamp)
    {
        uint PHNX_ID = identityRegistry.getPHNX_ID(approvingAddress);

        validateRemoveResolverForSignature(approvingAddress, PHNX_ID, resolver, isPhoenixIdentity, extraData, v, r, s, timestamp);

        removeResolver(PHNX_ID, resolver, isPhoenixIdentity, extraData);
    }

    function validateRemoveResolverForSignature(
        address approvingAddress, uint PHNX_ID, address resolver, bool isPhoenixIdentity, bytes memory extraData,
        uint8 v, bytes32 r, bytes32 s, uint timestamp
    )
        private view
    {
        require(
            identityRegistry.isSigned(
                approvingAddress,
                keccak256(
                    abi.encodePacked(
                        byte(0x19), byte(0), address(this),
                        "I authorize that these Resolvers be removed from my Identity.",
                        PHNX_ID, resolver, isPhoenixIdentity, extraData, timestamp
                    )
                ),
                v, r, s
            ),
            "Permission denied."
        );
    }

    // common logic to remove resolvers
    function removeResolver(uint PHNX_ID, address resolver, bool isPhoenixIdentity, bytes memory extraData) private {
        require(identityRegistry.isResolverFor(PHNX_ID, resolver), "Identity has not yet set this resolver.");
    
        delete resolverAllowances[PHNX_ID][resolver];
    
        if (isPhoenixIdentity) {
            PhoenixIdentityResolverInterface phoenixIdentityResolver = PhoenixIdentityResolverInterface(resolver);
            if (phoenixIdentityResolver.callOnRemoval())
                require(phoenixIdentityResolver.onRemoval(PHNX_ID, extraData), "Removal failure.");
            emit PhoenixIdentityResolverRemoved(PHNX_ID, resolver);
        }

        address[] memory resolvers = new address[](1);
        resolvers[0] = resolver;
        identityRegistry.removeResolversFor(PHNX_ID, resolvers);
    }

    function triggerRecoveryAddressChangeFor(
        address approvingAddress, address newRecoveryAddress, uint8 v, bytes32 r, bytes32 s
    )
        public
    {
        uint PHNX_ID = identityRegistry.getPHNX_ID(approvingAddress);
        uint nonce = signatureNonce[PHNX_ID]++;
        require(
            identityRegistry.isSigned(
                approvingAddress,
                keccak256(
                    abi.encodePacked(
                        byte(0x19), byte(0), address(this),
                        "I authorize this change of Recovery Address.",
                        PHNX_ID, newRecoveryAddress, nonce
                    )
                ),
                v, r, s
            ),
            "Permission denied."
        );

        identityRegistry.triggerRecoveryAddressChangeFor(PHNX_ID, newRecoveryAddress);
    }

    // allow contract to receive Phoenix tokens
    function receiveApproval(address sender, uint amount, address _tokenAddress, bytes memory _bytes) public {
        require(msg.sender == _tokenAddress, "Malformed inputs.");
        require(_tokenAddress == phoenixTokenAddress, "Sender is not the phoenix token smart contract.");

        // depositing to an PHNX_ID
        if (_bytes.length <= 32) {
            require(phoenixToken.transferFrom(sender, address(this), amount), "Unable to transfer token ownership.");
            uint recipient;
            if (_bytes.length < 32) {
                recipient = identityRegistry.getPHNX_ID(sender);
            }
            else {
                recipient = abi.decode(_bytes, (uint));
                require(identityRegistry.identityExists(recipient), "The recipient PHNX_ID does not exist.");
            }
            deposits[recipient] = deposits[recipient].add(amount);
            emit PhoenixIdentityDeposit(sender, recipient, amount);
        }
        // transferring to a via
        else {
            (
                bool isTransfer, address resolver, address via, uint to, bytes memory phoenixIdentityCallBytes
            ) = abi.decode(_bytes, (bool, address, address, uint, bytes));
            
            require(phoenixToken.transferFrom(sender, via, amount), "Unable to transfer token ownership.");

            PhoenixIdentityViaInterface viaContract = PhoenixIdentityViaInterface(via);
            if (isTransfer) {
                viaContract.phoenixIdentityCall(resolver, to, amount, phoenixIdentityCallBytes);
                emit PhoenixIdentityTransferToVia(resolver, via, to, amount);
            } else {
                address payable payableTo = address(to);
                viaContract.phoenixIdentityCall(resolver, payableTo, amount, phoenixIdentityCallBytes);
                emit PhoenixIdentityWithdrawToVia(resolver, via, address(to), amount);
            }
        }
    }

    // transfer PhoenixIdentity balance from one PhoenixIdentity holder to another
    function transferPhoenixIdentityBalance(uint PHNX_IDTo, uint amount) public {
        _transfer(identityRegistry.getPHNX_ID(msg.sender), PHNX_IDTo, amount);
    }

    // withdraw PhoenixIdentity balance to an external address
    function withdrawPhoenixIdentityBalance(address to, uint amount) public {
        _withdraw(identityRegistry.getPHNX_ID(msg.sender), to, amount);
    }

    // allows resolvers to transfer allowance amounts to other phoenixIdentitys (throws if unsuccessful)
    function transferPhoenixIdentityBalanceFrom(uint PHNX_IDFrom, uint PHNX_IDTo, uint amount) public {
        handleAllowance(PHNX_IDFrom, amount);
        _transfer(PHNX_IDFrom, PHNX_IDTo, amount);
        emit PhoenixIdentityTransferFrom(msg.sender);
    }

    // allows resolvers to withdraw allowance amounts to external addresses (throws if unsuccessful)
    function withdrawPhoenixIdentityBalanceFrom(uint PHNX_IDFrom, address to, uint amount) public {
        handleAllowance(PHNX_IDFrom, amount);
        _withdraw(PHNX_IDFrom, to, amount);
        emit PhoenixIdentityWithdrawFrom(msg.sender);
    }

    // allows resolvers to send withdrawal amounts to arbitrary smart contracts 'to' identities (throws if unsuccessful)
    function transferPhoenixIdentityBalanceFromVia(uint PHNX_IDFrom, address via, uint PHNX_IDTo, uint amount, bytes memory _bytes)
        public
    {
        handleAllowance(PHNX_IDFrom, amount);
        _withdraw(PHNX_IDFrom, via, amount);
        PhoenixIdentityViaInterface viaContract = PhoenixIdentityViaInterface(via);
        viaContract.phoenixIdentityCall(msg.sender, PHNX_IDFrom, PHNX_IDTo, amount, _bytes);
        emit PhoenixIdentityTransferFromVia(msg.sender, PHNX_IDTo);
    }

    // allows resolvers to send withdrawal amounts 'to' addresses via arbitrary smart contracts
    function withdrawPhoenixIdentityBalanceFromVia(
        uint PHNX_IDFrom, address via, address payable to, uint amount, bytes memory _bytes
    )
        public
    {
        handleAllowance(PHNX_IDFrom, amount);
        _withdraw(PHNX_IDFrom, via, amount);
        PhoenixIdentityViaInterface viaContract = PhoenixIdentityViaInterface(via);
        viaContract.phoenixIdentityCall(msg.sender, PHNX_IDFrom, to, amount, _bytes);
        emit PhoenixIdentityWithdrawFromVia(msg.sender, to);
    }

    function _transfer(uint PHNX_IDFrom, uint PHNX_IDTo, uint amount) private identityExists(PHNX_IDTo, true) returns (bool) {
        require(deposits[PHNX_IDFrom] >= amount, "Cannot withdraw more than the current deposit balance.");
        deposits[PHNX_IDFrom] = deposits[PHNX_IDFrom].sub(amount);
        deposits[PHNX_IDTo] = deposits[PHNX_IDTo].add(amount);

        emit PhoenixIdentityTransfer(PHNX_IDFrom, PHNX_IDTo, amount);
    }

    function _withdraw(uint PHNX_IDFrom, address to, uint amount) internal {
        require(to != address(this), "Cannot transfer to the PhoenixIdentity smart contract itself.");

        require(deposits[PHNX_IDFrom] >= amount, "Cannot withdraw more than the current deposit balance.");
        deposits[PHNX_IDFrom] = deposits[PHNX_IDFrom].sub(amount);
        require(phoenixToken.transfer(to, amount), "Transfer was unsuccessful");

        emit PhoenixIdentityWithdraw(PHNX_IDFrom, to, amount);
    }

    function handleAllowance(uint PHNX_IDFrom, uint amount) internal {
        // check that resolver-related details are correct
        require(identityRegistry.isResolverFor(PHNX_IDFrom, msg.sender), "Resolver has not been set by from tokenholder.");

        if (resolverAllowances[PHNX_IDFrom][msg.sender] < amount) {
            emit PhoenixIdentityInsufficientAllowance(PHNX_IDFrom, msg.sender, resolverAllowances[PHNX_IDFrom][msg.sender], amount);
            revert("Insufficient Allowance");
        }

        resolverAllowances[PHNX_IDFrom][msg.sender] = resolverAllowances[PHNX_IDFrom][msg.sender].sub(amount);
    }

    // allowAndCall from msg.sender
    function allowAndCall(address destination, uint amount, bytes memory data)
        public returns (bytes memory returnData)
    {
        return allowAndCall(identityRegistry.getPHNX_ID(msg.sender), amount, destination, data);
    }

    // allowAndCall from approvingAddress with meta-transaction
    function allowAndCallDelegated(
        address destination, uint amount, bytes memory data, address approvingAddress, uint8 v, bytes32 r, bytes32 s
    )
        public returns (bytes memory returnData)
    {
        uint PHNX_ID = identityRegistry.getPHNX_ID(approvingAddress);
        uint nonce = signatureNonce[PHNX_ID]++;
        validateAllowAndCallDelegatedSignature(approvingAddress, PHNX_ID, destination, amount, data, nonce, v, r, s);

        return allowAndCall(PHNX_ID, amount, destination, data);
    }

    function validateAllowAndCallDelegatedSignature(
        address approvingAddress, uint PHNX_ID, address destination, uint amount, bytes memory data, uint nonce,
        uint8 v, bytes32 r, bytes32 s
    )
        private view
    {
        require(
            identityRegistry.isSigned(
                approvingAddress,
                keccak256(
                    abi.encodePacked(
                        byte(0x19), byte(0), address(this),
                        "I authorize this allow and call.", PHNX_ID, destination, amount, data, nonce
                    )
                ),
                v, r, s
            ),
            "Permission denied."
        );
    }

    // internal logic for allowAndCall
    function allowAndCall(uint PHNX_ID, uint amount, address destination, bytes memory data)
        private returns (bytes memory returnData)
    {
        // check that resolver-related details are correct
        require(identityRegistry.isResolverFor(PHNX_ID, destination), "Destination has not been set by from tokenholder.");
        if (amount != 0) {
            resolverAllowances[PHNX_ID][destination] = resolverAllowances[PHNX_ID][destination].add(amount);
        }

        // solium-disable-next-line security/no-low-level-calls
        (bool success, bytes memory _returnData) = destination.call(data);
        require(success, "Call was not successful.");
        return _returnData;
    }

    // events
    event PhoenixIdentityProvidersUpgraded(uint indexed PHNX_ID, address[] newProviders, address[] oldProviders, address approvingAddress);

    event PhoenixIdentityResolverAdded(uint indexed PHNX_ID, address indexed resolver, uint withdrawAllowance);
    event PhoenixIdentityResolverAllowanceChanged(uint indexed PHNX_ID, address indexed resolver, uint withdrawAllowance);
    event PhoenixIdentityResolverRemoved(uint indexed PHNX_ID, address indexed resolver);

    event PhoenixIdentityDeposit(address indexed from, uint indexed PHNX_IDTo, uint amount);
    event PhoenixIdentityTransfer(uint indexed PHNX_IDFrom, uint indexed PHNX_IDTo, uint amount);
    event PhoenixIdentityWithdraw(uint indexed PHNX_IDFrom, address indexed to, uint amount);

    event PhoenixIdentityTransferFrom(address indexed resolverFrom);
    event PhoenixIdentityWithdrawFrom(address indexed resolverFrom);
    event PhoenixIdentityTransferFromVia(address indexed resolverFrom, uint indexed PHNX_IDTo);
    event PhoenixIdentityWithdrawFromVia(address indexed resolverFrom, address indexed to);
    event PhoenixIdentityTransferToVia(address indexed resolverFrom, address indexed via, uint indexed PHNX_IDTo, uint amount);
    event PhoenixIdentityWithdrawToVia(address indexed resolverFrom, address indexed via, address indexed to, uint amount);

    event PhoenixIdentityInsufficientAllowance(
        uint indexed PHNX_ID, address indexed resolver, uint currentAllowance, uint requestedWithdraw
    );
}
