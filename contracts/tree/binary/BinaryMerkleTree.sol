// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.4;

import "./Node.sol";
import "../Constants.sol";
import "../Utils.sol";
import "./TreeHasher.sol";
import "./Branch.sol";
import "./BinaryMerkleProof.sol";

/// @title Binary Merkle Tree.
/// @notice spec can be found at https://github.com/FuelLabs/fuel-specs/blob/master/specs/protocol/cryptographic_primitives.md#binary-merkle-tree.
library BinaryMerkleTree {
    /// @notice Get the pointer to a node in memory
    /// @param node: The node to get the pointer to
    /// @return ptr : The pointer to the node
    // solhint-disable-next-line func-visibility
    function getPtrToNode(Node memory node) internal pure returns (bytes32 ptr) {
        assembly {
            ptr := node
        }
    }

    /// @notice Get a node at a given pointer
    /// @param ptr: The pointer to the node
    /// @return node : The node
    // solhint-disable-next-line func-visibility
    function getNodeAtPtr(bytes32 ptr) internal pure returns (Node memory node) {
        assembly {
            node := ptr
        }
    }

    /// @notice Verify if element (key, data) exists in Merkle tree, given data, proof, and root.
    /// @param root: The root of the tree in which verify the given leaf
    /// @param data: The data of the leaf to verify
    /// @param key: The key of the leaf to verify.
    /// @param proof: Binary Merkle Proof for the leaf.
    /// @param numLeaves: The number of leaves in the tree
    /// @return : Whether the proof is valid
    /// @dev numLeaves is necessary to determine height of sub-tree containing the data to prove
    function verify(
        bytes32 root,
        bytes memory data,
        bytes32[] memory proof,
        uint256 key,
        uint256 numLeaves
    ) public pure returns (bool) {
        // Check proof is correct length for the key it is proving
        if (numLeaves <= 1) {
            if (proof.length != 0) {
                return false;
            }
        } else if (proof.length != pathLengthFromKey(key, numLeaves)) {
            return false;
        }

        // Check key is in tree
        if (key >= numLeaves) {
            return false;
        }

        // A sibling at height 1 is created by getting the hash of the data to prove.
        bytes32 digest = leafDigest(data);

        // Null proof is only valid if numLeaves = 1
        // If so, just verify hash(data) is root
        if (proof.length == 0) {
            if (numLeaves == 1) {
                return (root == digest);
            } else {
                return false;
            }
        }

        uint256 height = 1;
        uint256 stableEnd = key;

        // While the current subtree (of height 'height') is complete, determine
        // the position of the next sibling using the complete subtree algorithm.
        // 'stableEnd' tells us the ending index of the last full subtree. It gets
        // initialized to 'key' because the first full subtree was the
        // subtree of height 1, created above (and had an ending index of
        // 'key').

        while (true) {
            // Determine if the subtree is complete. This is accomplished by
            // rounding down the key to the nearest 1 << 'height', adding 1
            // << 'height', and comparing the result to the number of leaves in the
            // Merkle tree.

            uint256 subTreeStartIndex = (key / (1 << height)) * (1 << height);
            uint256 subTreeEndIndex = subTreeStartIndex + (1 << height) - 1;

            // If the Merkle tree does not have a leaf at index
            // 'subTreeEndIndex', then the subtree of the current height is not
            // a complete subtree.
            if (subTreeEndIndex >= numLeaves) {
                break;
            }
            stableEnd = subTreeEndIndex;

            // Determine if the key is in the first or the second half of
            // the subtree.
            if (proof.length <= height - 1) {
                return false;
            }
            if (key - subTreeStartIndex < (1 << (height - 1))) {
                digest = nodeDigest(digest, proof[height - 1]);
            } else {
                digest = nodeDigest(proof[height - 1], digest);
            }

            height += 1;
        }

        // Determine if the next hash belongs to an orphan that was elevated. This
        // is the case IFF 'stableEnd' (the last index of the largest full subtree)
        // is equal to the number of leaves in the Merkle tree.
        if (stableEnd != numLeaves - 1) {
            if (proof.length <= height - 1) {
                return false;
            }
            digest = nodeDigest(digest, proof[height - 1]);
            height += 1;
        }

        // All remaining elements in the proof set will belong to a left sibling\
        // i.e proof sideNodes are hashed in "from the left"
        while (height - 1 < proof.length) {
            digest = nodeDigest(proof[height - 1], digest);
            height += 1;
        }

        return (digest == root);
    }

    /// @notice Computes Merkle tree root from leaves.
    /// @param data: list of leaves' data in ascending for leaves order.
    /// @return : The root of the tree
    function computeRoot(bytes[] memory data) public pure returns (bytes32) {
        if (data.length == 0) {
            return Constants.EMPTY;
        }
        bytes32[] memory nodes = new bytes32[](data.length);
        for (uint256 i = 0; i < data.length; ++i) {
            nodes[i] = leafDigest(data[i]);
        }
        uint256 size = (nodes.length + 1) >> 1;
        uint256 odd = nodes.length & 1;
        // pNodes are nodes in previous level.
        // We use pNodes to avoid damaging the input leaves.
        bytes32[] memory pNodes = nodes;
        while (true) {
            uint256 i = 0;
            for (; i < size - odd; ++i) {
                uint256 j = i << 1;
                nodes[i] = nodeDigest(pNodes[j], pNodes[j + 1]);
            }
            if (odd == 1) {
                nodes[i] = pNodes[i << 1];
            }
            if (size == 1) {
                break;
            }
            odd = (size & 1);
            size = (size + 1) >> 1;
            pNodes = nodes;
        }
        return nodes[0];
    }

    /// @notice Appends a new element by calculating new root, returns new root and if successful, pure function.
    /// @param numLeaves, number of leaves in the tree currently.
    /// @param data, The data of the leaf to append.
    /// @param proof, Binary Merkle Proof to use for the leaf.
    /// @return : The root of the new tree
    /// @return : Whether the proof is valid
    function append(
        uint256 numLeaves,
        bytes memory data,
        bytes32[] memory proof
    ) public pure returns (bytes32, bool) {
        bytes32 digest = leafDigest(data);

        // Since appended leaf is last leaf in tree by definition, its path consists only of set bits
        // (because all side nodes will be on its left)
        // Therefore, the number of steps in the proof should equal number of bits set in the key
        // E.g. If appending the 7th leaf, key = 0b110 => proofLength = 2.

        uint256 proofLength = 0;
        while (numLeaves > 0) {
            proofLength += numLeaves & 1;
            numLeaves = numLeaves >> 1;
        }

        if (proof.length != proofLength) {
            return (Constants.NULL, false);
        }

        // If proof length is correctly 0, tree is empty, and we are appending the first leaf
        if (proofLength == 0) {
            digest = leafDigest(data);
        }
        // Otherwise tree non-empty so we calculate nodes up to root
        else {
            for (uint256 i = 0; i < proofLength; ++i) {
                digest = nodeDigest(proof[i], digest);
            }
        }

        return (digest, true);
    }

    /// @notice Adds a branch to the in-storage sparse representation of tree
    /// @dev We store the minimum subset of nodes necessary to calculate the root
    /// @param key: The key of the leaf
    /// @param value : The data of the leaf
    /// @param root : The root of the tree containing the added branch
    /// @param rootPtr : The pointer to the root node
    /// @param proof: The proof (assumed valid) of the leaf up to the root
    /// @param numLeaves: The total number of leaves in the tree
    /// @return : The pointer to the root node
    function addBranch(
        bytes32 key,
        bytes memory value,
        bytes32[] memory proof,
        bytes32 root,
        bytes32 rootPtr,
        uint256 numLeaves
    ) internal pure returns (bytes32) {
        // Handle case where tree has only one leaf (so it is the root)
        if (numLeaves == 1) {
            Node memory rootNode = Node(root, Constants.NULL, Constants.NULL);
            rootPtr = getPtrToNode(rootNode);
            return rootPtr;
        }
        uint256 startingBit = getStartingBit(numLeaves);

        AddBranchVariables memory variables;

        bytes32[] memory sideNodePtrs = new bytes32[](proof.length);
        bytes32[] memory nodePtrs = new bytes32[](proof.length);

        // Set root
        // When adding the first branch, rootPtr will not be set yet, set it here.
        if (rootPtr == Constants.NULL) {
            // Set the new root
            Node memory rootNode = Node(root, Constants.NULL, Constants.NULL);
            rootPtr = getPtrToNode(rootNode);
            variables.parent = rootNode;
        }
        // On subsequent branches, we need to retrieve root
        else {
            variables.parent = getNodeAtPtr(rootPtr);
        }

        // Step backwards through proof (from root down to leaf), getting pointers to the nodes/sideNodes
        // If node is not yet added, set digest to NULL (we'll set it when we hash back up the branch)
        for (uint256 i = proof.length; i > 0; i -= 1) {
            uint256 j = i - 1;

            // Descend into left or right subtree depending on key
            // If leaf is in the right subtree:
            if (getBitAtFromMSB(key, startingBit + proof.length - i) == 1) {
                // Subtree is on the right, so sidenode is on the left.
                // Check to see if sidenode already exists. If not, create it. and associate with parent
                if (variables.parent.leftChildPtr == Constants.NULL) {
                    variables.sideNode = Node(proof[j], Constants.NULL, Constants.NULL);
                    variables.sideNodePtr = getPtrToNode(variables.sideNode);
                    variables.parent.leftChildPtr = variables.sideNodePtr;
                } else {
                    variables.sideNodePtr = variables.parent.leftChildPtr;
                }

                // Check to see if node already exists. If not, create it. and associate with parent
                // Its digest is initially null. We calculate and set it when we climb back up the tree
                if (variables.parent.rightChildPtr == Constants.NULL) {
                    variables.node = Node(Constants.NULL, Constants.NULL, Constants.NULL);
                    variables.nodePtr = getPtrToNode(variables.node);
                    variables.parent.rightChildPtr = variables.nodePtr;
                } else {
                    variables.nodePtr = variables.parent.rightChildPtr;
                    variables.node = getNodeAtPtr(variables.nodePtr);
                }

                // Mirror image of preceding code block, for when leaf is in the left subtree
                // If subtree is on the left, sideNode is on the right
            } else {
                if (variables.parent.rightChildPtr == Constants.NULL) {
                    variables.sideNode = Node(proof[j], Constants.NULL, Constants.NULL);
                    variables.sideNodePtr = getPtrToNode(variables.sideNode);
                    variables.parent.rightChildPtr = variables.sideNodePtr;
                } else {
                    variables.sideNodePtr = variables.parent.rightChildPtr;
                }

                if (variables.parent.leftChildPtr == Constants.NULL) {
                    variables.node = Node(Constants.NULL, Constants.NULL, Constants.NULL);
                    variables.nodePtr = getPtrToNode(variables.node);
                    variables.parent.leftChildPtr = variables.nodePtr;
                } else {
                    variables.nodePtr = variables.parent.leftChildPtr;
                    variables.node = getNodeAtPtr(variables.nodePtr);
                }
            }

            // Keep pointers to sideNode and node
            sideNodePtrs[j] = variables.sideNodePtr;
            nodePtrs[j] = variables.nodePtr;

            variables.parent = variables.node;
        }

        // Set leaf digest
        Node memory leaf = getNodeAtPtr(nodePtrs[0]);
        leaf.digest = leafDigest(value);

        if (proof.length == 0) {
            return rootPtr;
        }

        // Go back up the tree, setting the digests of nodes on the branch
        for (uint256 i = 1; i < nodePtrs.length; i += 1) {
            variables.node = getNodeAtPtr(nodePtrs[i]);
            variables.node.digest = nodeDigest(
                getNodeAtPtr(variables.node.leftChildPtr).digest,
                getNodeAtPtr(variables.node.rightChildPtr).digest
            );
        }

        return rootPtr;
    }

    /// @notice Get the sidenodes for a given leaf key up to the root
    /// @param key: The key for which to find the sidenodes
    /// @param rootPtr: The memory pointer to the root of the tree
    /// @param numLeaves : The total number of leaves in the tree
    /// @return The sidenodes up to the root.
    function sideNodesForRoot(
        bytes32 key,
        bytes32 rootPtr,
        uint256 numLeaves
    ) internal pure returns (bytes32[] memory) {
        // Allocate a large enough array for the sidenodes (we'll shrink it later)
        bytes32[] memory sideNodes = new bytes32[](256);

        Node memory currentNode = getNodeAtPtr(rootPtr);

        // If the root is a placeholder, the tree is empty, so there are no sidenodes to return.
        // The leaf pointer is the root pointer
        if (currentNode.digest == Constants.ZERO) {
            bytes32[] memory emptySideNodes;
            return emptySideNodes;
        }

        // If the root is a leaf, the tree has only one leaf, so there are also no sidenodes to return.
        // The leaf pointer is the root pointer
        if (isLeaf(currentNode)) {
            bytes32[] memory emptySideNodes;
            return emptySideNodes;
        }

        // Tree has at least 2 leaves
        SideNodesFunctionVariables memory variables;

        variables.sideNodeCount = 0;

        uint256 startingBit = getStartingBit(numLeaves);
        uint256 pathLength = pathLengthFromKey(uint256(key), numLeaves);

        // Descend the tree from the root according to the key, collecting side nodes
        for (uint256 i = startingBit; i < startingBit + pathLength; i++) {
            (variables.leftNodePtr, variables.rightNodePtr) = parseNode(currentNode);
            // Bifurcate left or right depending on bit in key
            if (getBitAtFromMSB(key, i) == 1) {
                (variables.nodePtr, variables.sideNodePtr) = (
                    variables.rightNodePtr,
                    variables.leftNodePtr
                );
            } else {
                (variables.nodePtr, variables.sideNodePtr) = (
                    variables.leftNodePtr,
                    variables.rightNodePtr
                );
            }

            sideNodes[variables.sideNodeCount] = variables.sideNodePtr;
            variables.sideNodeCount += 1;

            currentNode = getNodeAtPtr(variables.nodePtr);
        }

        return reverseSideNodes(shrinkBytes32Array(sideNodes, variables.sideNodeCount));
    }

    /// @notice Update a given leaf
    /// @param key: The key of the leaf to be added
    /// @param value: The data to update the leaf with
    /// @param sideNodes: The sideNodes from the leaf to the root
    /// @param numLeaves: The total number of leaves in the tree
    /// @return currentPtr : The pointer to the root of the tree
    function updateWithSideNodes(
        bytes32 key,
        bytes memory value,
        bytes32[] memory sideNodes,
        uint256 numLeaves
    ) public pure returns (bytes32 currentPtr) {
        Node memory currentNode = hashLeaf(value);
        currentPtr = getPtrToNode(currentNode);

        // If numleaves <= 1, then the root is just the leaf hash (or ZERO)
        if (numLeaves > 1) {
            uint256 startingBit = getStartingBit(numLeaves);
            uint256 pathLength = pathLengthFromKey(uint256(key), numLeaves);

            for (uint256 i = 0; i < pathLength; i += 1) {
                if (getBitAtFromMSB(key, startingBit + pathLength - 1 - i) == 1) {
                    currentNode = hashNode(
                        sideNodes[i],
                        currentPtr,
                        getNodeAtPtr(sideNodes[i]).digest,
                        currentNode.digest
                    );
                } else {
                    currentNode = hashNode(
                        currentPtr,
                        sideNodes[i],
                        currentNode.digest,
                        getNodeAtPtr(sideNodes[i]).digest
                    );
                }

                currentPtr = getPtrToNode(currentNode);
            }
        }
    }

    /// @notice Add an array of branches and update one of them
    /// @param branches: The array of branches to add
    /// @param root: The root of the tree
    /// @param key: The key of the leaf to be added
    /// @param value: The data to update the leaf with
    /// @param numLeaves: The total number of leaves in the tree
    /// @return newRoot : The new root of the tree
    function addBranchesAndUpdate(
        MerkleBranch[] memory branches,
        bytes32 root,
        bytes32 key,
        bytes memory value,
        uint256 numLeaves
    ) public pure returns (bytes32 newRoot) {
        bytes32 rootPtr = Constants.ZERO;
        for (uint256 i = 0; i < branches.length; i++) {
            rootPtr = addBranch(
                branches[i].key,
                branches[i].value,
                branches[i].proof,
                root,
                rootPtr,
                numLeaves
            );
        }

        bytes32[] memory sideNodes = sideNodesForRoot(key, rootPtr, numLeaves);
        bytes32 newRootPtr = updateWithSideNodes(key, value, sideNodes, numLeaves);

        return getNodeAtPtr(newRootPtr).digest;
    }

    /// @notice Derive the proof for a new appended leaf from the proof for the last appended leaf
    /// @param oldProof: The proof to the last appeneded leaf
    /// @param lastLeaf: The last leaf hash
    /// @param key: The key of the new leaf
    /// @return : The proof for the appending of the new leaf
    /// @dev This function assumes that oldProof has been verified in position (key - 1)
    function deriveAppendProofFromLastProof(
        bytes32[] memory oldProof,
        bytes32 lastLeaf,
        uint256 key
    ) public pure returns (bytes32[] memory) {
        // First prepend last leaf to its proof.
        bytes32[] memory newProofBasis = new bytes32[](oldProof.length + 1);
        newProofBasis[0] = leafDigest(abi.encodePacked(lastLeaf));
        for (uint256 i = 0; i < oldProof.length; i += 1) {
            newProofBasis[i + 1] = oldProof[i];
        }

        // If the new leaf is "even", this will already be the new proof
        if (key & 1 == 1) {
            return newProofBasis;
        }

        // Otherwise, get the expected length of the new proof (it's the last leaf by definition, so numLeaves = key + 1)
        // Assuming old proof was valid, this will always be shorter than the old proof.
        uint256 expectedProofLength = pathLengthFromKey(key, key + 1);

        bytes32[] memory newProof = new bytes32[](expectedProofLength);

        // "Hash up" through old proof until we have the correct first sidenode
        bytes32 firstSideNode = newProofBasis[0];
        uint256 hashedUpIndex = 0;
        while (hashedUpIndex < (newProofBasis.length - expectedProofLength)) {
            firstSideNode = nodeDigest(newProofBasis[hashedUpIndex + 1], firstSideNode);
            hashedUpIndex += 1;
        }

        // Set the calculated first side node as the first element in the proof
        newProof[0] = firstSideNode;

        // Then append the remaining (unchanged) sidenodes, if any
        for (uint256 j = 1; j < expectedProofLength; j += 1) {
            newProof[j] = newProofBasis[hashedUpIndex + j];
        }

        return newProof;
    }

    struct AddBranchVariables {
        bytes32 nodePtr;
        bytes32 sideNodePtr;
        Node node;
        Node parent;
        Node sideNode;
    }

    /// @notice A struct to hold variables of the sidenodes function in memory
    /// @dev Necessary to circumvent stack-too-deep errors caused by too many
    /// @dev variables on the stack.
    struct SideNodesFunctionVariables {
        bytes32 leftNodePtr;
        bytes32 rightNodePtr;
        bytes32 nodePtr;
        bytes32 sideNodePtr;
        uint256 sideNodeCount;
    }
}
