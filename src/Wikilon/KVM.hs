
-- | First-Class Key-Value Databases
--
-- Wikilon.DB offers a mutable key-value database with stowage and GC.
-- This KVM models a key-value database model above stowage, enabling
-- first class database values to potentially be larger than memory.
-- 
-- The tree structure used here is a variant of the crit-bit tree (CBT).
-- Differences from conventional crit-bit tree:
--
-- - least key is held by parent, to support full tree diffs and merges
-- - each key is associated with a binary value (which may be empty)
-- - keys, values, nodes may be stowed outside of volatile memory
--
-- Keys and values within the KVM are free to reference other stowage 
-- resources. But keys mustn't have any trailing null bytes.
--
-- Batched updates are important: it's inefficient to allocate lots of
-- short-lived nodes at the stowage layers. This module will aim to make
-- batching and buffering relatively simple and easy.
--
-- First-class database values offer a lot of benefits over conventional
-- key-value databases: histories, forking, diffs, composition. Wikilon
-- relies on KVM for most data indexing and processing. 
--
module Wikilon.KVM
    (
    ) where

import qualified Data.ByteString.Lazy as LBS

-- keys mustn't have trailing nulls.
validKey :: LBS.ByteString -> Bool
validKey s = LBS.null s || (0 /= LBS.last s)


-- | A simple trie with bytestring data. 

