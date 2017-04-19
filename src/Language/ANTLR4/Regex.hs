{-# LANGUAGE DeriveLift #-}
module Language.ANTLR4.Regex (Regex(..), parseRegex, regexP) where
import Language.Haskell.TH.Lift (Lift(..))
import Text.ParserCombinators.Parsec
import qualified Text.Parsec.String     as PS
import qualified Text.Parsec.Prim       as PP
import qualified Text.Parsec.Token      as PT
import qualified Text.Parsec.Expr       as PE
import qualified Text.Parsec.Combinator as PC
import Data.Char (ord)
import Text.ParserCombinators.Parsec.Language
import qualified Debug.Trace as D -- trace, traceM

--traceM s = D.traceM ("[Regex] " ++ s)
traceM = return

data Regex s =
    Epsilon
  | Literal   [s]
  | Union     (Regex s) (Regex s)
  | Concat    [Regex s]
  | Kleene    (Regex s)
  | PosClos   (Regex s)
  | Question  (Regex s)
  | CharSet   [s] -- TODO: Set s, and ranges of characters
  deriving (Lift, Eq, Show)
-- TODO: Lex regexs (e.g. complement sets, escape chars, ...)

(<||>) a b = try a <|> try b

rEOF' = do
  (eof >>= return . const True)
  <||>
  (return False)

parseRegex :: String -> Either ParseError (Regex Char)
parseRegex input = PP.parse (regexP rEOF') "" input

type RegexC = Regex Char

-- convert list of sequential regexes into a single regex
list2regex []  = Epsilon
list2regex [x] = x
list2regex xs  = Concat xs

{- rEOF is a parser to indicate when it's okay to stop parsing the regex -}
regexP :: PS.Parser Bool -> PS.Parser RegexC
regexP rEOF = let

  regexP' :: PS.Parser [RegexC]
  regexP' = do
    r <- regexElement
    traceM $ "regexP: " ++ show r
    whiteSpace
    b <- rEOF
    traceM $ "regexP: " ++ show b
    y <- getInput
    traceM $ show y
    if b
      then return [r]
      else do
        rs <- regexP'
        return $ r:rs
    <?> "regexP"

  in do
    xs <- regexP'
    return $ list2regex xs

regexElement :: PS.Parser RegexC
regexElement = do
  whiteSpace
  r <- charSet <||> literal <||> concatR
  traceM $ "regexElement: " ++ show r
  p <- optionMaybe (satisfy (`elem` "+*?"))
  traceM $ "regexElement: " ++ show p
  return (case p of
    Nothing  -> r
    Just '+' -> PosClos  r
    Just '*' -> Kleene   r
    Just '?' -> Question r
    Just _   -> undefined)
  

many2 p = do { x <- p; xs <- many p; return (x:xs) }

concatR :: PS.Parser RegexC
concatR = do
  traceM "<concatR>"
  c <- many1 (charSet <||> literal) >>= return . Concat
  traceM "</concatR>"
  return c

-- regex string literal uses single quotes
literal :: PS.Parser RegexC
literal = PC.between (satisfy (== '\'')) (satisfy (== '\'')) (many singleChar >>= (return . Literal))

charSet :: PS.Parser RegexC
charSet = do
  traceM "<charSet>"
  cset <- PC.between (satisfy (== '[')) (satisfy (== ']')) (charSetBody >>= (return . CharSet))
  traceM $ "</charSet>: " ++ show cset
  return cset

charSetBody :: PS.Parser [Char]
charSetBody = do
  traceM $ "<charSetBody>"
  xs <- many $ charSetRange <||> (singleChar >>= (\c -> return [c]))
  traceM $ "charSetBody: " ++ (show $ concat xs)
  return $ concat xs

charSetRange :: PS.Parser [Char]
charSetRange = do
  start <- singleChar
  reservedOp "-"
  end   <- singleChar
  if ord end <= ord start
    then unexpected [end]
    else return [start..end]

singleChar = escapedChar <||> satisfy (\c -> not (c `elem` ['\'', ']']))

escapedChar :: PS.Parser Char
escapedChar = (do
    reservedOp "\\"
    reservedOp "'"
    return '\'')
  <||> (do
    reservedOp "\\"
    reservedOp "]"
    return ']')
  <||> (do
    reservedOp "\\"
    reservedOp "["
    return '[')

regexLexer :: PT.TokenParser ()
regexLexer = PT.makeTokenParser $ haskellStyle
  { reservedOpNames = ["[", "]", "\\", "-", "+"] }

whiteSpace    = PT.whiteSpace  regexLexer
identifier    = PT.identifier  regexLexer
operator      = PT.operator    regexLexer
reserved      = PT.reserved    regexLexer
reservedOp    = PT.reservedOp  regexLexer
charLiteral   = PT.charLiteral regexLexer
stringLiteral = PT.stringLiteral  regexLexer
integer       = PT.integer     regexLexer
natural       = PT.natural     regexLexer
commaSep1     = PT.commaSep1   regexLexer
parens        = PT.parens      regexLexer
braces        = PT.braces      regexLexer
brackets      = PT.brackets    regexLexer
