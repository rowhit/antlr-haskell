{-# LANGUAGE ScopedTypeVariables, FlexibleInstances, MultiParamTypeClasses
  , DeriveGeneric, DeriveAnyClass, TypeFamilies, FlexibleContexts
  , StandaloneDeriving, OverloadedStrings #-}
module Text.ANTLR.Grammar
  ( Ref(..), sameNTs, sameTs
  , ProdElem(..), ProdElems
  , Production(..), ProdRHS(..), StateFncn(..)
  , Predicate(..), Mutator(..)
  , Grammar(..), getRHS, getLHS
  , defaultGrammar
  , isSem, isAction
  , isNT, isT, isEps, getNTs, getTs, getEps
  , prodsFor, getProds
  , validGrammar, hasAllNonTerms, hasAllTerms, startIsNonTerm
  , symbols, Hashable(..), Generic(..)
  ) where
import Prelude hiding (pi)
import Data.List (nub, sort)

import System.IO.Unsafe (unsafePerformIO)
import qualified Debug.Trace as D

import qualified Text.ANTLR.Set as S
import Text.ANTLR.Set
  ( Set(..), empty, fromList, member, union
  , Hashable(..), Generic(..)
  )

import Text.ANTLR.Pretty

uPIO :: IO a -> a
uPIO = unsafePerformIO

----------------------------------------------------------------
-- When we *Show* production elements, they should contain source location
-- information, but when we *compare* them, we should ignore the source info.

-- Something is "Ref" if it can be symbolized by some symbol in a set of
-- symbols. Symbols are typically Strings, an enum data type, or some other
-- Eq-able (best if finite) set of things.
class Ref v where
  -- One symbol type for every value type v.
  type Sym v :: *
  getSymbol :: v -> Sym v

compareSymbols :: (Ref ref, Eq (Sym ref)) => ref -> ref -> Bool
compareSymbols a b = getSymbol a == getSymbol b

-- Nonterminals can be symbolized (for now the types are equivalent, i.e.
-- nt == Sym nt)
sameNTs :: forall nt. (Ref nt, Eq (Sym nt)) => nt -> nt -> Bool
sameNTs = compareSymbols

-- Terminals can be symbolized (in the current implementation, the input
-- terminal type to a parser is (t == Token n v) and the terminal symbol type is
-- (ts == Sym t == n) where n is defined as the name of a token (Token n v).
sameTs :: forall t. (Ref t, Eq (Sym t)) => t -> t -> Bool
sameTs = compareSymbols

instance Ref String where
  type Sym String = String
  getSymbol = id

instance Ref (String, b) where
  type Sym (String, b) = String
  getSymbol = fst

-- Grammar ProdElems. nts == Non Terminal Symbol (type), ts == Terminal Symbol (type)
-- Production elements are only used in the grammar data structure and parser,
-- therefore these types (nt and ts) are *not* necessarily equivalent to the
-- terminal types seen by the tokenizer (nonterminals are special because no one
-- sees them until after parsing). Also pushing (ts = Sym t) up to the top of
-- data constructors gets rid of a lot of unnecessary standalone deriving
-- instances. Standalone deriving instances in this case are a programming
-- anti-pattern for allowing you to improperly parametrize your types. In this
-- case a ProdElem cares about the *terminal symbol type*, not the *terminal
-- token type*. In fact it's redundant to say "terminal token" because all
-- tokens are terminals in the grammar. A token is by definition a tokenized
-- *value* with a *named* terminal symbol, which is in fact exactly what the
-- Token type looks like in Text.ANTLR.Lex.Tokenizer: Token n v (name and
-- value). So wherever I see an 'n' type variable in the tokenizer, this is
-- equivalent to (Sym t) in the parser. And wherever I see a (Token n v) in the
-- tokenizer, this gets passed into the parser as 't':
-- - n           == Sym t
-- - (Token n v) == t
data ProdElem nts ts =
    NT nts
  | T  ts
  | Eps
  deriving (Eq, Ord, Generic, Hashable, Show)

instance (Prettify nts, Prettify ts) => Prettify (ProdElem nts ts) where
  prettify (NT nts) = prettify nts
  prettify (T  ts)  = prettify  ts
  prettify Eps      = pStr "ε"

isNT (NT _) = True
isNT _      = False

isT (T _) = True
isT _     = False

isEps Eps = True
isEps _   = False

getNTs = map (\(NT nt) -> nt) . filter isNT
getTs  = map (\(T t) -> t) . filter isT
getEps = map (\Eps -> Eps) . filter isEps -- no

type ProdElems nts ts = [ProdElem nts ts]

data StateFncn s =
    Pass                   -- No predicate or mutator
  | Sem    (Predicate s)   -- Semantic predicate
  | Action (Mutator s)     -- Mutator, ProdElems is always empty in this one
  deriving (Eq, Ord, Generic, Hashable, Show)

instance Prettify (StateFncn s) where
  prettify Pass       = return ()
  prettify (Sem p)    = prettify p
  prettify (Action a) = prettify a

data ProdRHS s nts ts = Prod (StateFncn s) (ProdElems nts ts)
  deriving (Eq, Ord, Generic, Hashable, Show)

instance (Prettify s, Prettify nts, Prettify ts) => Prettify (ProdRHS s nts ts) where
  prettify (Prod sf ps) = do
    prettify sf
    prettify ps

isSem (Prod (Sem _) _) = True
isSem _ = False

isAction (Prod (Action _) _) = True
isAction _ = False

getProds = map (\(Prod _ ss) -> ss)

data Production s nts ts = Production nts (ProdRHS s nts ts)
  deriving (Eq, Ord, Generic, Hashable)

instance (Prettify s, Prettify nts, Prettify ts) => Prettify (Production s nts ts) where
  prettify (Production nts (Prod sf ps)) = do
    len <- pCount nts
    -- Put the indentation level after the nonterminal, or just incr by 2 if
    -- lazy...
    incrIndent (len + 4)
    pStr " -> "
    prettify sf
    prettify ps
    incrIndent (-4)

instance (Show s, Show nts, Show ts) => Show (Production s nts ts) where
  show (Production nts rhs) = show nts ++ " -> " ++ show rhs

getRHS :: Production s nts ts -> ProdRHS s nts ts
getRHS (Production lhs rhs) = rhs

getLHS :: Production s nts ts -> nts
getLHS (Production lhs rhs) = lhs

-- Get only the productions for the given nonterminal symbol nts:
prodsFor :: forall s nts ts. (Eq nts) => Grammar s nts ts -> nts -> [Production s nts ts]
prodsFor g nts = let
    matchesNT :: Production s nts t -> Bool
    matchesNT (Production nts' _) = nts' == nts
  in filter matchesNT (ps g)

-- TODO: boiler plate auto deriving for "named" of a user defined type?

-- Predicates and Mutators act over some state. The String
-- identifiers should eventually correspond to source-level
-- e.g. location / allocation site information, i.e. two
-- predicates or mutators are equivalent iff they were
-- constructed from the same production rule.
data Predicate s = Predicate String (s -> Bool)

instance Eq (Predicate s) where
  Predicate p1 _ == Predicate p2 _ = p1 == p2

instance Ord (Predicate s) where
  Predicate p1 _ `compare` Predicate p2 _ = p1 `compare` p2

instance Show (Predicate s) where
  show (Predicate p1 _) = "π(" ++ show p1 ++ ")"

instance Hashable (Predicate s) where
  hashWithSalt salt (Predicate p1 _) = salt `hashWithSalt` p1

instance Prettify (Predicate s) where
  prettify (Predicate n _) = pStr' n

instance Prettify (Mutator s) where
  prettify (Mutator n _) = pStr' n

data Mutator   s = Mutator String (s -> s)

instance Eq (Mutator s) where
  Mutator m1 _ == Mutator m2 _ = m1 == m2

instance Ord (Mutator s) where
  Mutator m1 _ `compare` Mutator m2 _ = m1 `compare` m2

instance Show (Mutator s) where
  show (Mutator m1 _) = "µ(" ++ show m1 ++ ")"

instance Hashable (Mutator s) where
  hashWithSalt salt (Mutator m1 _) = salt `hashWithSalt` m1

data Grammar s nts ts = G
  { ns  :: Set nts
  , ts  :: Set ts
  , ps  :: [Production s nts ts]
  , s0  :: nts
  , _πs :: Set (Predicate s)
  , _μs :: Set (Mutator   s)
  } deriving (Show)

instance (Eq s, Eq nts, Eq ts, Hashable nts, Hashable ts, Prettify s, Prettify nts, Prettify ts)
  => Eq (Grammar s nts ts) where
  g1 == g2 = ns g1 == ns g2
          && ts g1 == ts g2
          && eqLists (nub $ ps g1) (nub $ ps g2)
          && s0 g1 == s0 g2
          && _πs g1 == _πs g2
          && _μs g1 == _μs g2

eqLists [] [] = True
eqLists [] vs = False
eqLists vs [] = False
eqLists (v1:vs) vs2 = eqLists vs (filter (/= v1) vs2)

instance (Prettify s, Prettify nts, Prettify ts, Hashable ts, Eq ts, Hashable nts, Eq nts, Ord ts, Ord nts)
  => Prettify (Grammar s nts ts) where
  prettify G {ns = ns, ts = ts, ps = ps, s0 = s0, _πs = _πs, _μs = _μs} = do
    pLine "Grammar:"
    pStr "{ "
    incrIndent 2
    pStr  "  ns = "      ; prettify ns; pLine ""
    pStr  ", ts = "      ; prettify ts; pLine ""
    pStr  ", ps = "      ; pListLines $ sort ps; pLine ""
    pStr  ", s0 = "      ; prettify s0; pLine ""
    pStr  ", _πs = "     ; prettify _πs ; pLine ""
    pStr  ", _μs = "     ; prettify _μs ; pLine ""
    incrIndent (-2)
    pStr "}"

symbols
  :: (Ord nts, Ord ts, Hashable s, Hashable nts, Hashable ts)
  => Grammar s nts ts -> Set (ProdElem nts ts)
symbols g = S.insert Eps $ S.map NT (ns g) `union` S.map T (ts g)

defaultGrammar
  :: forall s nts ts. (Ord ts, Hashable ts, Hashable nts, Eq nts)
  => nts -> Grammar s nts ts
defaultGrammar start = G
  { ns  = empty
  , ts  = empty
  , ps  = []
  , _πs = empty
  , _μs = empty
  , s0  = start
  }

validGrammar
  :: forall s nts ts.
  (Eq nts, Ord nts, Eq ts, Ord ts, Hashable nts, Hashable ts)
  => Grammar s nts ts -> Bool
validGrammar g =
     hasAllNonTerms g
  && hasAllTerms g
  && startIsNonTerm g
--  && distinctTermsNonTerms g

hasAllNonTerms
  :: (Eq nts, Ord nts, Hashable nts, Hashable ts)
  => Grammar s nts ts -> Bool
hasAllNonTerms g =
  ns g == (fromList . getNTs . concat . getProds . map getRHS $ ps g)

hasAllTerms
  :: (Eq ts, Ord ts, Hashable nts, Hashable ts)
  => Grammar s nts ts -> Bool
hasAllTerms g =
  ts g == (fromList . getTs . concat . getProds . map getRHS $ ps g)

startIsNonTerm
  :: (Ord nts, Hashable nts)
  => Grammar s nts ts -> Bool
startIsNonTerm g = s0 g `member` ns g

--distinctTermsNonTerms g =
--  (ns g `intersection` ts g) == empty

