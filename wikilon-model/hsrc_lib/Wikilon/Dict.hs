-- | Awelon Object (AO) Dictionary Model
--
-- A dictionary is simply an association from words to definitions.
--
-- In Wikilon, a definition is a function that returns a value and a
-- function to compile this value. The result of compilation is also
-- a function, the meaning of the definition.
--
--      type Def a b = ∃v.∀e. e→([v→[a→b]]*(v*e))
--
-- Within a definition, value `v` serves a role as a syntax, perhaps
-- a DSL or content for a structured editor. The function `[v→[a→b]]` 
-- is the compiler for the value `v`. Applying compiler to value will
-- return function `[a→b]`, which is the meaning of the definition.
-- Usefully, the identity function is a valid compiler for low level
-- code, where [a→b] is expressed directly as an opaque function.
--
-- Dependencies between words use tokens of form {%foo} and {%bar}.
-- Dependencies must be acyclic and are contained to the dictionary.
-- Static compilation and linking can be achieved by inlining the 
-- compiled [a→b] meaning for each word. The resulting ABC stream
-- may be interpreted or further compiled for performance.
--
-- In a healthy dictionary:
--
--   1. every word is defined
--   2. dependencies are acyclic
--   3. all definitions compile
--   4. every meaning typechecks
--
-- During development, it is not unusual for words to be undefined.
-- This is common for top-down programming, and to represent 'holes'
-- in a dictionary that may be filled with support of type inference,
-- tests analysis, simulations or machine learning, etc.. 
--
-- Typechecking isn't precisely defined for AO or ABC. In general, 
-- it includes all sorts of linting and abstract interpretation to
-- find errors. A goal of Awelon project is to be very open to adding
-- new automatic, continuous background analyses such that developers
-- can have near real-time information about dictionary health. 
--
-- Wikilon ensures that dictionaries are acyclic. Undefined words are
-- permitted because they're useful for development. Wikilon requires
-- dictionaries obey some strict constraints on the ABC. Only four
-- token types are permitted (words, annotations, discretionary sealer,
-- discretionary unsealer). Tokens and texts are further constrained to
-- ensure easy interaction with HTML forms, URLs, etc.. Typechecking
-- and other higher validation is left to background processes.
--

module Wikilon.Dict
    ( DictView(..)
    , wordDeps, abcWords
    , toMap, wordsInDict
    , WordPrefix
    , DictSplitPrefix(..)
    , DictRLU(..)
    , wordClients
    , DictUpdate(..)
    , renameDictWord
    , deleteDictWord
    , deleteDictWords
    , safeUpdateWords
    , safeRenameWord
    , safeMergeWords
    , InsertionError(..)
    , Cycle, testForCycle
    , testForMalformedDef
    , module Wikilon.Dict.Word
    ) where

import Prelude hiding (lookup)
import Data.Maybe (mapMaybe)
import Data.Monoid
import qualified Data.List as L
import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Control.Monad.State as State

import Awelon.ABC (ABC)
import qualified Awelon.ABC as ABC

import Wikilon.Dict.Word 
import Wikilon.Dict.Text
import Wikilon.Dict.Token

-- | Basic view of a dictionary. Note that an undefined word will
-- return the empty ABC string (mempty). 
--
-- Note that an empty definition is distinct from an identity definition
-- due to the staging. An identity function has a form such as `[][]`.
class DictView dict where
    -- | Lookup the ABC definition for a word in a dictionary.
    lookup :: dict -> Word -> ABC

    -- | Lookup the raw bytestring for a definition. This has a default
    -- implementation, but may be optimized for a model.
    lookupBytes :: dict -> Word -> LazyUTF8.ByteString
    lookupBytes d = ABC.encode . lookup d

    -- | Obtain complete listing for dictionary.
    toList :: dict -> [(Word, ABC)]

    -- | Find a list of words that are distinct between two dictionaries.
    -- The default implementation is an exhaustive search. Ideally, we can
    -- perform a much more efficient implementation for the dict rep.
    dictDiff :: dict -> dict -> [Word]
    dictDiff a b = Map.keys $ mapDiff (==) (toMap a) (toMap b)

-- generic 2-way diff element
data MapDiff a b = LeftOnly a | RightOnly b | FoundDiff a b
-- map diff given equality function
mapDiff :: (Ord k) => (a -> b -> Bool) -> Map k a -> Map k b -> Map k (MapDiff a b)
mapDiff eq = Map.mergeWithKey jf lf rf where
    lf = fmap LeftOnly
    rf = fmap RightOnly
    jf _ a b | eq a b = Nothing
             | otherwise = Just (FoundDiff a b)

-- | Obtain a map of words and definitions.
toMap :: (DictView dict) => dict -> Map Word ABC
toMap = Map.fromList . toList

-- | Obtain a list of words defined within from a dictionary.
wordsInDict :: (DictView dict) => dict -> [Word]
wordsInDict = fmap fst . toList

-- | Find all words depended upon by a given word. Filters ABC for just
-- the {%word} tokens, and returns each word. Word dependencies may occur
-- anywhere within a definition.
wordDeps :: (DictView dict) => dict -> Word -> [Word]
wordDeps d = abcWords . lookup d

-- | Each word is expressed as a {%word} token in the original ABC.
abcWords :: ABC -> [Word]
abcWords = mapMaybe wordTok . ABC.tokens where
    wordTok tok = case UTF8.uncons tok of
        Just ('%', w) -> Just (Word w)
        _ -> Nothing

-- | A word prefix is a bytestring. It is *not* necessarily a full
-- UTF-8 string, i.e. because we might split on a UTF-8 character.
type WordPrefix = BS.ByteString

-- | for browsing a dictionary in a breadth-first manner
class (DictView dict) => DictSplitPrefix dict where
    -- | Given a prefix, provide a list of strictly larger prefixes
    -- that have words with non-empty definitions. Further, will
    -- return whether the given prefix accepts a word.
    splitOnPrefix :: WordPrefix -> dict -> (Bool,[WordPrefix])

    -- | Obtain a complete list of words with a given prefix.
    wordsWithPrefix :: WordPrefix -> dict -> [Word]

-- | It's very useful to know who uses what. We'll do this at the
-- granularity of individual tokens, since it's also very useful
-- to quickly discover all clients of a discretionary sealer or
-- annotation.
class (DictView dict) => DictRLU dict where
    -- | Find clients of an arbitrary token.
    tokenClients :: dict -> Token -> [Word]

-- | Find direct clients of a word.
wordClients :: (DictRLU dict) => dict -> Word -> [Word]
wordClients d = tokenClients d . BS.cons 37 . unWord

-- | Update definitions in a dictionary. Note that no validation
-- logic is performed by these operations. Any validation must be
-- performed in a wrapper function.
--
-- Deleting a dictionary word is equivalent to updating a definition
-- to the empty ABC program.
class (DictView dict) => DictUpdate dict where
    updateDictWord :: Word -> ABC -> dict -> dict

    updateDictWords :: Map Word ABC -> dict -> dict
    updateDictWords = flip (L.foldl' upd) . Map.toList where
        upd d (w,abc) = updateDictWord w abc d 

-- | update a word's definition to the empty ABC program
deleteDictWord :: (DictUpdate dict) => Word -> dict -> dict
deleteDictWord = flip updateDictWord mempty

-- | delete a list of words.
deleteDictWords :: (DictUpdate dict) => [Word] -> dict -> dict
deleteDictWords = updateDictWords . Map.fromList . withEmpties where
    withEmpties = flip L.zip $ L.repeat mempty

-- | Rename a word in a dictionary, affecting not just that word
-- but also all the words that reference it. Note: no validation
-- is performed, and this will overwrite the second word. In general,
-- it is safest to rename under one of two conditions:
--
--   1. the target word is undefined and unused (cf. safeRenameWord)
--   2. target and origin share same definition (cf. safeMergeWords)
--
-- In these conditions, you can be sure that clients of a word are not
-- impacted, do not need to be retested or recompiled, no cycles are
-- introduced, etc.. Otherwise, you must treat the rename as an update
-- to both the origin and target words.
-- 
renameDictWord :: (DictUpdate dict, DictRLU dict) => Word -> Word -> dict -> dict
renameDictWord wo wt d =
    if (wo == wt) then d else -- trivially, no change
    let lC = wordClients d wo in -- client of wo, for rewrite wo→wt
    let fnUpdClient = _renameInABC wo wt . lookup d in -- rename wo to wt
    flip updateDictWords d $ 
        Map.insert wt (lookup d wo) $                 -- overwrite wt
        Map.insert wo mempty $                        -- delete wo
        Map.fromList $ L.zip lC (fmap fnUpdClient lC) -- update clients of wo

-- rename a word within context of ABC
_renameInABC :: Word -> Word -> ABC -> ABC
_renameInABC wo wt = ABC.rewriteTokens rwTok where
    t0 = BS.cons 37 $ wordToUTF8 wo
    tf = BS.cons 37 $ wordToUTF8 wt
    rnTok t = if (t == t0) then tf else t
    rwTok t = ABC.mkABC [ABC.ABC_Tok (rnTok t)]


-- | Rename a word only if the target word is undefined and has no
-- clients. Otherwise returns Nothing.
safeRenameWord :: (DictUpdate dict, DictRLU dict) => Word -> Word -> dict -> Maybe dict
safeRenameWord wo wt d =
    let bUndefinedTarget = L.null $ ABC.abcOps $ lookup d wt in
    let bTargetHasNoClients = L.null $ wordClients d wt in
    let bOkRename = bUndefinedTarget && bTargetHasNoClients in
    if not bOkRename then Nothing else
    Just $ renameDictWord wo wt d

-- | Merge a word only if origin and target words have the same
-- definitions. Otherwise return Nothing.
safeMergeWords :: (DictUpdate dict, DictRLU dict) => Word -> Word -> dict -> Maybe dict
safeMergeWords wo wt d =
    let bOkMerge = (lookup d wo) == (lookup d wt) in
    if not bOkMerge then Nothing else
    Just $ renameDictWord wo wt d

-- | Errors recognized by safeUpdateWords
data InsertionError 
    = BadWord  !Word         -- word is not valid according to heuristics
    | BadToken !Token !Word  -- invalid {token} used within word's definition
    | BadText  !Text !Word   -- rejecting text on heuristic constraints
    | Cycle    ![Word]       -- a cycle was discovered
    | DupWord  !Word         -- word appears multiple times in request
    deriving (Eq, Ord)

instance Show InsertionError where
    show (BadWord w)    = "malformed word: " ++ show w
    show (BadToken t w) = "rejecting token " ++ show (ABC.ABC_Tok t) ++ " in " ++ show w
    show (Cycle ws)     = "cyclic dependencies: " ++ show ws
    show (BadText t w)  = "in word" ++ show w ++ " malformed text: " ++ show (ABC.ABC_Text t)
    show (DupWord w)    = "word " ++ show w ++ " is assigned more than once"

-- | Update words after testing for the most obvious, cheaply discovered
-- errors. Normal updates to a dictionary should be performed via this
-- function to guard against cycles and so on. In case of errors, this
-- tries to return many errors at once.
--
-- Note that leaving words undefined is not considered an error at this
-- layer. (And we'd have difficulty distinguishing a valid definition
-- anyway.) Undefined words shall be treated as holes in later stage.
safeUpdateWords :: (DictUpdate dict) => [(Word, ABC)] -> dict -> Either [InsertionError] dict
safeUpdateWords [] d = Right d
safeUpdateWords l d =
    let lWords = fmap fst l in
    let lDupErrors = fmap DupWord $ findDups $ lWords in
    let lMalformed = L.concatMap (uncurry testForMalformedDef) l in
    let d' = updateDictWords (Map.fromList l) d in
    let lCycleErrors = case testForCycle lWords d' of
            Nothing -> []
            Just (w,ws) -> [Cycle (w:ws)]
    in
    let lErrors = lDupErrors ++ lMalformed ++ lCycleErrors in
    if L.null lErrors then Right d' else Left lErrors

findDups :: (Eq a) => [a] -> [a]
findDups = f [] where
    f r (x:xs) =
        let bNewDup = L.elem x xs && L.notElem x r in
        if bNewDup then f (x:r) xs else f r xs
    f r [] = L.reverse r

-- | Validate constraints on internal tokens and words.
testForMalformedDef :: Word -> ABC -> [InsertionError]
testForMalformedDef w = (malformedWord ++) . abcErrors where
    malformedWord = if isValidWord w then [] else [BadWord w]
    abcErrors = L.concatMap opError . ABC.abcOps
    opError (ABC.ABC_Tok t) | not (isValidToken t) = [BadToken t w]
    opError (ABC.ABC_Text t) | not (isValidText t) = [BadText t w]
    opError (ABC.ABC_Block b) = abcErrors b
    opError _ = []

-- | A cycle is expressed as a chain of dependencies that is implicitly
-- closed on the first word. 
type Cycle a = (a,[a])

-- | Search under a given list of words for cycles. If such a cycle
-- exists, this function certainly finds it. However, I won't attempt 
-- to return an exhaustive set of cycles. 
testForCycle :: (DictView dict) => [Word] -> dict -> Maybe (Cycle Word)
testForCycle ws d = flip State.evalState mempty $ fc (wordDeps d) [] ws

-- | generic cycle discovery given an adjacency list and an initial
-- frontier.
fc :: (Ord a) => (a -> [a]) -> [a] -> [a] -> State.State (Set a) (Maybe (Cycle a))
fc _ _ [] = return Nothing
fc adj stack (x:xs) =
    State.gets (Set.member x) >>= \ bSafe ->
    if bSafe then fc adj stack xs else
    if L.elem x stack then return $ Just (_cyc x stack) else
    fc adj (x:stack) (adj x) >>= \ cycleUnderX ->
    case cycleUnderX of
        Nothing -> State.modify (Set.insert x) >> fc adj stack xs
        cycleFound -> return cycleFound 
    
-- return just the cycle found (implicitly closed)
_cyc :: (Eq a) => a -> [a] -> (a,[a])
_cyc a stack = (,) a $ L.dropWhile (/= a) $ L.reverse stack

