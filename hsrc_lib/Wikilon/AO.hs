{-# LANGUAGE ViewPatterns, PatternGuards #-}
-- | The Awelon Object (AO) language is essentially a macro language
-- for Awelon Bytecode (ABC). AO will trivially expand and compile
-- into bytecode. AO makes ABC accessible to humans, without being
-- opaque - i.e. one can gain a good feel for the bytecode via use
-- of AO.
--
-- Wikilon uses parsers based on the `cereal` class. This is convenient
-- for efficient integration with serializers and acid-state. Wikilon's
-- parser for AO is slightly simplified from that used in the original
-- 'awelon' project, mostly favoring a less sophisticated number type.
-- useful for both 
-- Wikilon will use a simplified parser for AO. I'm not going to worry
-- about good parse errors, since (a) AO definitions are too small for
-- detailed location informaiton to matter, and (b) I'll likely have a
-- structured editor before long. Wikilon will be a bit more accepting,
-- allowing all inline ABC primitive operators except for SP and LF.
--
-- I shall still forbid words to start with `@` for escapes, control
-- control, export; or `%` for inline ABC. I'll reserve the unicode 
-- white brackets, braces, parens. 
--
-- At the moment, I haven't decided quite how I want to implement
-- embedded literal objects. I still like the idea, but it might be
-- better to treat them as special objects or words on the wiki.
--
-- I still plan to eventually support Ambiguous AO, where we can
-- define a whole search-space of programs very quickly by use of
-- phrases like: `(0|1|2)(foo|bar)(baz|qux)`. Likely, this will be
-- a special IDE-supported search rather than a runtime search.
--
-- Wikilon will still limit which capabilities may be embedded in
-- source code to just sealers and annotations. Anything else
-- must be provided via powerblock (or whatever).
-- 
module Wikilon.AO
    ( AO_Code(..), AO_Action(..), PrimOp(..)
    , aoWords, aoMapWords
    , getAO, getAO', putAO
    , module Wikilon.Word
    ) where

import Control.Applicative
import Control.Monad (join)
import Control.Exception (assert)
import qualified Data.List as L
import qualified Data.Decimal as Dec

import qualified Data.Binary as B
import qualified Data.Binary.Get as B
import qualified Data.Binary.Put as B

import qualified Codec.Binary.UTF8.Generic as UTF8
import Data.Ratio
import Data.String
--import Data.Char (ord)

import qualified Wikilon.ParseUtils as P
import Wikilon.ABC
import Wikilon.Word
import Wikilon.Char

-- | AO_Code mostly exists for read, show, serialization instances.
newtype AO_Code = AO_Code { ao_code :: [AO_Action] } deriving (Eq, Ord)

-- | AO code is simply a (usually very short) list of actions.
-- Use of words refer to the larger dictionary. Tokens offer
-- access to annotations or side-effects. 
data AO_Action
    = AO_Word  {-# UNPACK #-} !Word
    | AO_Block [AO_Action]
    | AO_Num   {-# UNPACK #-} !Rational -- simple numbers
    | AO_Text  String   -- literal text (inline or multi-line)
    | AO_ABC   [PrimOp] -- inline ABC as a pseudo-word (grouping preserved)
    | AO_Tok   String   -- {token}
    deriving (Eq, Ord)

-- | Extract the words used by AO code. For example:
--     foo "hello" [42 bar baz] %vrwlc bar → [foo,bar,baz,bar]
-- Duplicates are still part of the list at this point.
aoWords :: AO_Code -> [Word]
aoWords = flip lw [] . ao_code where
    lw (x:xs) = ew x . lw xs
    lw [] = id
    ew (AO_Word w) = (w:)
    ew (AO_Block ops) = lw ops
    ew _ = id

-- | Apply a name transform to every word in some AO code. It's up
-- to the user to ensure this is a sensible transform. :)
aoMapWords :: (Word -> Word) -> AO_Code -> AO_Code
aoMapWords f = AO_Code . fmap mw . ao_code where
    mw (AO_Word w) = AO_Word (f w)
    mw (AO_Block ops) = AO_Block (fmap mw ops)
    mw action = action

instance B.Binary AO_Code where
    put = putAO . ao_code
    get = AO_Code <$> getAO True

instance Show AO_Action where
    showsPrec _ = showList . (:[])
    showList = shows . AO_Code

instance Show AO_Code where
    show = UTF8.toString . B.encode
    -- default showList

-- Read is mostly for convenience. It shouldn't be used directly
-- because the conversions between ByteString and String have a
-- lot of overhead.
instance Read AO_Code where
    readsPrec _ s = 
        let bytes = UTF8.fromString s in
        case B.decodeOrFail bytes of
            Left (_bs,_ct,_emsg) -> []
            Right (brem,_ct, code) -> [(code, UTF8.toString brem)]

instance IsString AO_Code where 
    fromString s = 
        let bytes = UTF8.fromString s in
        case B.decodeOrFail bytes of
            Left (_brem,_ct,_emsg) ->
                let sRem = UTF8.toString _brem in
                error $ "\nAO  parse error: " ++ _emsg 
                     ++ "\nbytes remaining: " ++ sRem
            Right (brem,_ct, code) -> 
                let sRem = UTF8.toString brem in
                if (L.null sRem) then code else
                error $ "\nparsed OK: " ++ show code
                     ++ "\nhalted at: " ++ sRem

-- | Serialize AO into binary. 
putAO :: [AO_Action] -> B.PutM ()
putAO (op:ops) = putAction op >> putSP ops
putAO [] = return ()

-- put a space then put the next action (if any).
--
-- Text always adds SP for inline text or LF for multiline text. To
-- avoid doubling number of spaces, text is treated as special case. 
putSP :: [AO_Action] -> B.PutM ()
putSP [] = return ()
putSP (AO_Text txt : ops) = putSPText txt >> putSP ops 
putSP ops = B.put ' ' >> putAO ops

putAction :: AO_Action -> B.Put
putAction (AO_Word w) = B.putByteString (wordToUTF8 w)
putAction (AO_Block ao) = B.put '[' >> putAO ao >> B.put ']'
putAction (AO_ABC abc) = B.put '%' >> mapM_ (B.put . abcOpToChar) abc
putAction (AO_Num n) = putNum n
putAction (AO_Text txt) = putSPText txt
putAction (AO_Tok tok) = putTok tok

putNum :: Rational -> B.PutM ()
putNum (toDecimal -> Just dec) = putShow dec
putNum r = putShow (numerator r) >> B.put '/' >> putShow (denominator r)

toDecimal :: Rational -> Maybe Dec.Decimal
toDecimal = either (const Nothing) Just . Dec.eitherFromRational

-- put string directly (no container/wrapper)
putShow :: (Show a) => a -> B.PutM ()
putShow = mapM_ B.put . show

-- conservatively add spaces or newlines before text literals
-- (this ensures a safe parse in a broader range of contexts).
putSPText :: String -> B.PutM ()
putSPText t | isInlineText t = B.put ' ' >> B.put '"' >> mapM_ B.put t >> B.put '"'
            | otherwise      = B.put '\n' >> B.put '"' >> putMLT t >> B.put '\n' >> B.put '~'

-- inline text if it's relatively short and contains only characters
-- that may be part of inline text (i.e. no LF or double quote).
isInlineText :: String -> Bool
isInlineText t = 
    let maxInlineTextLen = 64 in
    let (hd,tl) = L.splitAt maxInlineTextLen t in
    (null tl) && (L.all isInlineTextChar hd) 

putMLT :: String -> B.PutM ()
putMLT ('\n':cs) = B.put '\n' >> B.put ' ' >> putMLT cs -- escape LF
putMLT (c:cs) = B.put c >> putMLT cs
putMLT [] = return ()

putTok :: String -> B.PutM ()
putTok tok = assert (validTok tok) $ B.put '{' >> mapM_ B.put tok >> B.put '}'

validTok :: String -> Bool
validTok = L.all isTokenChar

-- | Get AO actions adjusted for whether we start at a new line.
getAO :: Bool -> B.Get [AO_Action]
getAO b = snd <$> getAO' b

-- | Get as many actions as we can, skipping any final white space.
-- we're right at the edge of what's available! The additional
-- boolean indicates whether we ended just after a newline.
getAO' :: Bool -> B.Get (Bool, [AO_Action])
getAO' = B.label "toplevel AO parser" . loop [] where
    loop ra bLF = 
        skipWS bLF >>= \ bLF' ->
        P.tryCommit (tryPeekAction bLF') >>= \ mbAction ->
        case mbAction of
            Nothing -> return (bLF', L.reverse ra)
            Just a  -> loop (a:ra) False


-- `fbySep x` insists that we get an element x and it is followed by
-- a word separator. Separators include SP, LF, [], (|), and EOF. Not
-- all separators are valid AO.
fbySep :: B.Get a -> B.Get a
fbySep getElem =
    getElem >>= \ a ->
    let pw8 = B.lookAhead B.getWord8 in
    (pw8 <|> return 32) >>= \ sep8 ->
    let sepC = toEnum $ fromIntegral sep8 in
    if isWordSep sepC then return a else
    fail "expecting word separator or EOF"

-- skip whitespace, and return whether we're at the start of a new line.
skipWS :: Bool -> B.Get Bool
skipWS bPrevLF =
    (B.lookAhead B.getWord8 <|> pure 4) >>= \ w8 ->
    let bLF = (10 == w8) in
    let bSP = (32 == w8) in
    let bWS = bLF || bSP in
    if not bWS then return bPrevLF else
    B.skip 1 >> skipWS bLF

-- AO is LL1, so we'll commit after reading one character.
-- For text, we need to know whether we're starting at a new line.
-- Blocks are the only type of value that don't need to be followed
-- by a word separator, since the ']' is already a word separator.
tryPeekAction :: Bool -> B.Get (B.Get AO_Action)
tryPeekAction bLF = B.get >>= \ c -> pka c where
    pka '%'               = pure $ fbySep $ AO_ABC <$> inlineABC
    pka '['               = pure $ AO_Block <$> blockLiteral 
    pka '{'               = pure $ fbySep $ AO_Tok <$> tokenAction
    pka '"' | bLF         = pure $ fbySep $ AO_Text <$> multiLineText
            | otherwise   = pure $ fbySep $ AO_Text <$> inlineText
    pka c | isDigit c     = pure $ fbySep $ AO_Num <$> numLiteral c
    pka c | isPMD c       = pure $ fbySep $ pmdAction c
    pka c | isWordStart c = pure $ fbySep $ AO_Word <$> normalWord [c]
    pka _ = fail "no AO action"

parseAction :: Bool -> B.Get AO_Action
parseAction = join . tryPeekAction

-- we've already parsed the '%' at the start.
-- we need at least one operation; but many 
-- are allowed e.g. %vrwlc
inlineABC :: B.Get [PrimOp]
inlineABC = B.label "inline ABC" $ P.many1 primOp where
    errSP  = "spaces are not valid inline ABC"
    errC c = '\'' : c : "' not recognized as inline ABC" 
    primOp = 
        B.get >>= \ c ->
        if isSpace c then fail errSP else
        case abcCharToOp c of
            Just op -> return op
            Nothing -> fail (errC c)

-- We've just entered a block via '['. Now parse to following ']'. 
-- The clear terminal makes this case easier than getAO. We also
-- know we do not start with an LF, so whitespace is easier.
blockLiteral :: B.Get [AO_Action]
blockLiteral = B.label "AO block parser" $ loop [] where
    loop ra = skipWS False >>= \ bLF -> body ra bLF
    body ra bLF = (endBlock ra) <|> (action ra bLF)
    endBlock ra = P.char ']' >> return (L.reverse ra)
    action ra bLF = parseAction bLF >>= loop . (:ra)

-- we've parsed the first '"'; now parse to end!
multiLineText :: B.Get String
multiLineText = B.label "AO multi-line text" $ 
    lineOfText >>= \ t0 ->
    P.manyTil (P.char ' ' >> lineOfText) (P.char '~') >>= \ ts ->
    return $ L.concat $ t0 : fmap ('\n':) ts

-- text to end of line...
lineOfText :: B.Get String
lineOfText = P.manyTil B.get (P.char '\n')

-- already parsed leading '"'; parse to following '"' for inline text
-- inline text excludes \n and ". (AO uses no escapes for text.)
inlineText :: B.Get String
inlineText = B.label "AO inline text" $ P.manyTil txchr (P.char '"') where
    txchr = P.satisfy isInlineTextChar

-- from '{' to following '}', token string.
-- token text forbids {, }, and \n.
tokenAction :: B.Get String
tokenAction = B.label "AO token" $ P.manyTil tokchr (P.char '}') where
    tokchr = P.satisfyMsg "token text" isTokenChar

-- parse a number. The simplified form of AO for Wikilon supports
-- only decimals (e.g. 3.14, 42) and fractionals (e.g. 3/4). This
-- is for simplicity purposes, and to de-emphasize bit banging,
-- though developers may certainly translate.
numLiteral :: Char -> B.Get Rational
numLiteral '0' = optFracPart 0
numLiteral d | isDigit d = posInt d >>= optFracPart
numLiteral c = fail $ c : " is not a digit!"

posInt :: Char -> B.Get Integer
posInt d = 
    P.many (P.satisfy isDigit) >>= \ ds ->
    return $ L.foldl addDigit 0 (d:ds)

addDigit :: Integer -> Char -> Integer
addDigit n d = (10*n) + dToN d

dToN :: Char -> Integer
dToN d = fromIntegral $ (fromEnum d) - 48

optFracPart :: Integer -> B.Get Rational
optFracPart n = maybe (fromInteger n) ($ n) <$> P.tryCommit (B.get >>= fp) where
    fp '.' = return decimalPart
    fp '/' = return fractionalPart
    fp _   = fail "no fractional part; undo! undo!"

decimalPart :: B.Get (Integer -> Rational)
decimalPart = B.label "decimal" $ 
    P.many1 (P.satisfy isDigit) >>= \ ds ->
    let num = L.foldl addDigit 0 ds in
    let den = 10 ^ (L.length ds) in
    let r = (num % den) in
    assert ((0 <= r) && (r < 1)) $
    return ((+ r) . fromInteger)

fractionalPart :: B.Get (Integer -> Rational)
fractionalPart = B.label "fractional" $
    P.satisfy isNZDigit >>= \ d -> 
    posInt d >>= \ den ->
    return (% den)
    
-- Parsing a number or a word, and rejecting some visually confusing
-- cases (e.g. `.3` or `+4`) from being parsed at all. Negative numbers
-- are routed through this parser.
pmdAction :: Char -> B.Get AO_Action
pmdAction c0 =
    P.optionMaybe (P.satisfy isWordCont) >>= \ mbc ->
    case mbc of
        Nothing -> return (AO_Word (textToWord [c0]))
        Just c1 ->
            if not (isDigit c1) then AO_Word <$> normalWord [c0,c1] else
            let pmdMsg = "To limit confusion with numbers, words starting with \
                         \+, -, /, or . may not use 0-9 as second character."
            in
            if not ('-' == c0) then fail pmdMsg else
            numLiteral c1 >>= \ r ->
            if (0 == r) then fail "refusing to parse a negative zero" else
            return (AO_Num (negate r))

-- I'm assuming the first one or two characters are already captured
-- in the argument, so we're now just parsing to the end of the word.
normalWord :: String -> B.Get Word
normalWord w0 =
    assert (not (L.null w0)) $
    P.many (P.satisfy isWordCont) >>= \ ws ->
    return (textToWord (w0 ++ ws))

