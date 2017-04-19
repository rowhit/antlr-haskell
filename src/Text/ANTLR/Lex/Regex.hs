{-# LANGUAGE ScopedTypeVariables #-}
module Text.ANTLR.Lex.Regex where

import Text.ANTLR.Set (Hashable, singleton, fromList)
import Text.ANTLR.Lex.NFA
import qualified Text.ANTLR.Lex.DFA as DFA

data Regex s =
    Epsilon
  | Symbol     s
  | Union      (Regex s) (Regex s)
  | Concat     [Regex s]
  | Kleene     (Regex s)
  | PosClos    (Regex s)
  | Class      [s]
  | MultiUnion [Regex s]

regex2nfa' ::
  forall s i. (Hashable i, Ord i, Hashable s, Eq s)
  => (i -> Int) -> (Int -> i) -> Regex s -> NFA s i
regex2nfa' from to r = let
    r2n :: Regex s -> NFA s i
    r2n Epsilon         = list2nfa [ (to 0, singleton   NFAEpsilon, to 1) ]
    r2n (Symbol s)      = list2nfa [ (to 0, singleton $ Edge s,     to 1) ]
    r2n (Union r1 r2)   = nfaUnion   from to (r2n r1) (r2n r2)
    r2n (Concat [])     = r2n Epsilon -- TODO: empty concat 
    r2n (Concat (r:rs)) = foldl (nfaConcat  from to) (r2n r) (map r2n rs)
    r2n (Kleene r1)     = nfaKleene  from to (r2n r1)
    r2n (PosClos r1)    = r2n $ Concat [r1, Kleene r1]
    r2n (Class [])      = r2n Epsilon -- TODO: empty character class shouldn't accept empty string?
    r2n (Class (s:ss))  = list2nfa [ (to 0, fromList $ map Edge $ s:ss, to 1) ] --r2n $ foldl Union (Symbol s) (map Symbol ss)
    r2n (MultiUnion []) = r2n Epsilon
    r2n (MultiUnion (r:rs)) = r2n $ foldl Union r rs
  in r2n r 

regex2nfa :: (Hashable s, Ord s) => Regex s -> NFA s Int
regex2nfa = regex2nfa' id id

regex2dfa :: (Hashable s, Ord s) => Regex s -> DFA.DFA s (DFAState Int)
regex2dfa = nfa2dfa . regex2nfa
