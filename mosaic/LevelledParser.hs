{-# LANGUAGE DataKinds, KindSignatures, GADTs, TupleSections, ViewPatterns
           , FlexibleContexts, InstanceSigs, ScopedTypeVariables
           , TypeOperators, ConstraintKinds, PolyKinds, RankNTypes
           , StandaloneDeriving, TypeFamilies, MultiParamTypeClasses
           , FlexibleInstances #-}

import Control.Applicative
import Control.Monad
import Data.Char
import GHC.Exts
import Data.Type.Equality
import Data.Map (Map)
import qualified Data.Map as Map
import Data.List
import GHC.TypeLits (Symbol, KnownSymbol)

data Nat = Z | S Nat -- >    data Nat :: level l . *l where Z :: Nat; S :: Nat ~> Nat

data Nat' :: Nat -> * where
  Z' :: Nat' Z
  S' :: Nat' n -> Nat' (S n)

sameNat :: Nat' a -> Nat' b -> Maybe (a :~: b)
Z' `sameNat` Z' = Just Refl
S' a `sameNat` S' b | Just Refl <- a `sameNat` b = Just Refl
_ `sameNat` _ = Nothing

{-
data Nat' :: level l . Nat -> *(1+l) where
  Z' :: Nat' Z
  S' :: Nat' n -> Nat' (S n)
  data Foo :: Nat' x
    Bar :: Foo

Bar :: Foo _::_ Nat' x :: *1

       Bar :: Foo _::_ Nat' x :: *2
-}

data Dict :: (k -> Constraint) -> k -> * where
  Dict :: c k => Dict c k

data AMDict :: (* -> *) -> * where
  AMDict :: (Alternative t, Monad t) => AMDict t

class KnownStratum (stratum :: Nat) where
  stratum :: Nat' stratum
  canDescend :: Nat' stratum -> Nat' below -> Maybe (stratum :~: S below, Dict KnownStratum below)

instance KnownStratum Z where stratum = Z'; canDescend _ _ = Nothing
instance KnownStratum n => KnownStratum (S n) where
  stratum = S' stratum
  canDescend (S' s) b | Just Refl <- s `sameNat` b = Just (Refl, Dict)
  canDescend _ _ = Nothing

class P (parser :: Nat -> * -> *) where
  type State parser
  peek :: parser s a -> parser s (a, State parser)
  accept :: State parser -> parser s ()

  star :: KnownStratum s => parser s ()
  reserved :: String -> parser s ()
  operator :: String -> parser s ()
  identifier :: parser s String
  constructor :: parser s String
  ascend :: parser (S s) a -> parser s a
  descend :: parser s a -> parser (S s) a
  failure :: parser s a
  token :: parser s a -> parser s a

-- Precedence climbing expression parser
--  http://eli.thegreenplace.net/2012/08/02/parsing-expressions-by-precedence-climbing

data Precedence = Pdontuse | Peq | Parr | P0 | P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 | P9 | Papp | Pat deriving (Eq, Ord)
data Associativity = AssocNone | AssocLeft | AssocRight deriving (Eq, Ord)

precedenceClimb :: (P parser, Alternative (parser s), Monad (parser s)) => parser s atom -> Map (Precedence, Associativity) (parser s atom -> parser s (atom -> atom)) -> parser s atom
precedenceClimb atom ops = go atom' ops'
  where atom' = atom <|> do operator "("; a <- go atom' ops'; operator ")"; return a -- FIXME
        ops' = Map.toList ops
        go atom curr = do let done = ((Pdontuse, AssocNone), const $ return id)
                              munchRest = choice $ map (uncurry parse) (done : curr)
                              munchWith p predicate = do b <- p (go atom $ filter predicate curr)
                                                         c <- munchRest
                                                         return $ \a -> c (b a)
                              choice = foldr1 (<|>)
                              parse (Pdontuse, _) p = p atom
                              parse (x, AssocNone) p = p atom <|> munchWith p (\((y,_),_) -> y > x)
                              parse (x, AssocRight) p = p atom <|> munchWith p (\((y,_),_) -> y >= x)
                              parse (x, AssocLeft) p = p atom <|> munchWith p (\((y,_),_) -> y > x)
                          a <- atom
                          rest <- munchRest
                          return $ rest a

expr1 :: CharParse (S Z) (Typ (S Z))
expr1 = precedenceClimb (Named <$> constructor) $ Map.fromList [((Parr, AssocRight), \atomp -> do operator "~>"; b <- atomp; return (`Arr`b))]

expr10 :: CharParse (S Z) (Typ (S Z))
expr10 = precedenceClimb atom $ Map.fromList [((Papp, AssocLeft), \atomp -> do peek atomp; b <- atomp; return (`App`b))]
  where atom = Named <$> constructor

expr11 :: CharParse (S Z) (Typ (S Z))
expr11 = precedenceClimb atom $ Map.fromList
                 [ ((Parr, AssocRight), \atomp -> do operator "~>"; b <- atomp; return (`Arr`b))
                 , ((P7, AssocRight), \atomp -> do operator "°"; b <- atomp; return (`App`b))
                 , ((P8, AssocLeft), \atomp -> do operator "`"; i <- identifier; guard $ i /= "rrr"; operator "`"; b <- atomp; return (\a -> Named i `App` a `App` b))
                 , ((P9, AssocRight), \atomp -> do operator "`"; i <- identifier; guard $ i == "rrr"; operator "`"; b <- atomp; return (\a -> Named i `App` a `App` b))
                 , ((Papp, AssocLeft), \atomp -> do (b, state) <- peek atomp; accept state; return (`App`b))
                 ]
  where atom = Named <$> constructor

-- NOTE: we need to rule out mixed associativity operators with same precedence in one compound expression
--    see: http://stackoverflow.com/questions/15964064/left-associative-operators-vs-right-associative-operators



-- NOTE: Later this will be just expression (which is stratum aware)
typeExpr :: forall parser s ty . (Universe ty, P parser, KnownStratum s, Alternative (parser s), Monad (parser s)) => parser s (ty s)
typeExpr = precedenceClimb atom $ Map.fromList operators
  where atom = starType <|> namedType
        starType = do star; S' S'{} <- return (stratum :: Nat' s); return tStar
        namedType = do S'{} <- return (stratum :: Nat' s); tNamed <$> (constructor <|> identifier)
        operators = [ ((Parr, AssocRight), \atom -> do operator "~>"; b <- atom; S'{} <- return (stratum :: Nat' s); return (`tArr`b))
                    , ((P9, AssocLeft), \atom -> do operator "`"; i <- namedType; operator "`"; b <- atom; return (\a -> i `tApp` a `tApp` b))
                    , ((Papp, AssocLeft), \atom -> do (b, state) <- peek atom; accept state; return (`tApp`b))
                    ]

class Pattern (exp :: Nat -> *) where
  pStar :: KnownStratum (S (S stratum)) => exp (S (S stratum))
  pApp :: exp stratum -> exp stratum -> exp stratum
  pNamed :: String -> exp stratum
  pAt :: exp stratum {-named! TODO-} -> exp stratum -> exp stratum
  pWildcard :: exp stratum
  pEq :: exp stratum -> exp stratum -> exp stratum

instance Pattern Pat where
  pStar = PStar
  pApp = PApp
  pNamed = PNamed
  pAt = PAt
  pWildcard = PWildcard
  pEq = PEq

-- The pattern language encompasses quite a bit more than what
-- is classically considered a pattern. We also lump equations
-- and (later?) signatures into the mix.
-- In a separate pass we check that all appear in a coherent manner.
--
pattern :: forall parser s exp . (Pattern exp, P parser, KnownStratum s, Alternative (parser s), Monad (parser s)) => parser s (exp s)
pattern = precedenceClimb atom $ Map.fromList operators
  where atom = starPat <|> namedPat <|> wildcardPat
        starPat = do star; S' S'{} <- return (stratum :: Nat' s); return pStar
        namedPat = pNamed <$> (constructor <|> identifier)
        wildcardPat = operator "_" >> pure pWildcard
        operators = [ ((Peq, AssocNone), \atom -> do operator "="; b <- atom; return (`pEq`b))
                    , ((Pat, AssocRight), \atom -> do operator "@"; b <- atom; return (`pAt`b))
                    , ((Papp, AssocLeft), \atom -> do (b, state) <- peek atom; accept state; return (`pApp`b))
                    ]

signature :: forall parser s . (P parser, KnownStratum s, Alternative (parser (S s)), Monad (parser s), Monad (parser (S s))) => parser s (Signature s)
signature = do name <- constructor
               operator "::"
               typ <- ascend typeExpr
               return $ Signature name typ

dataDefinition :: forall parser s . (P parser, KnownStratum s) => (forall strat . AMDict (parser strat)) -> parser (S s) (DefData (S s))
dataDefinition d
           = case (d :: AMDict (parser (S (S s))), d :: AMDict (parser (S s)), d :: AMDict (parser s)) of
               (AMDict, AMDict, AMDict) ->
                 do reserved "data"
                    sig <- signature
                    reserved "where"
                    let inhabitant = case stratum :: Nat' s of
                                       str@(S' b) -> case canDescend str b of
                                         Nothing -> Left <$> signature
                                         Just (Refl, Dict) -> Right <$> dataDefinition d
                                       _ -> Left <$> signature
                    inhabitants <- descend $ many inhabitant
                    return $ DefData sig inhabitants

-- for now this is a *type* Universe, later it may represent all
-- expressions (values/types/kinds, etc.)
--
class Universe (ty :: Nat -> *) where
  tStar :: KnownStratum (S (S stratum)) => ty (S (S stratum))
  tArr :: ty (S stratum) -> ty (S stratum) -> ty (S stratum)
  tApp :: ty stratum -> ty stratum -> ty stratum
  tNamed :: String -> ty (S stratum)

instance Universe Typ where
  tStar = Star
  tArr = Arr
  tApp = App
  tNamed = Named

data Typ (stratum :: Nat) where
  Star :: KnownStratum (S (S stratum)) => Typ (S (S stratum))
  Arr :: Typ (S stratum) -> Typ (S stratum) -> Typ (S stratum)
  App :: Typ stratum -> Typ stratum -> Typ stratum
  Named :: String -> Typ (S stratum)

infixr 0 `Arr`
infixl 9 `App`

deriving instance Show (Typ stratum)

data Pat (stratum :: Nat) where
  PStar :: KnownStratum (S (S stratum)) => Pat (S (S stratum))
  PApp :: Pat stratum -> Pat stratum -> Pat stratum
  PNamed :: String -> Pat stratum
  PAt :: Pat stratum -> Pat stratum -> Pat stratum
  PWildcard :: Pat stratum
  PEq :: Pat stratum -> Pat stratum -> Pat stratum

deriving instance Show (Pat stratum)

-- binds : "Just" --> [], "Just a" --> ["a"]
-- toplev : Bool -- TODO
-- how can we rule out the pattern (Just (a b)) statically?
--  Note: it is a valid expression
data Patt (path :: Path) (binds :: [Symbol]) (stratum :: Nat) where
  PStarr :: KnownStratum (S (S stratum)) => Patt path '[] (S (S stratum))
  PAppp :: Patt (Lapp path) binds stratum -> Patt (Rapp path) binds' stratum -> Patt path (binds `Append` binds') stratum
  PConstructor :: String -> Patt path '[] stratum
  -- not yet PVar :: (ValidVarPath path, KnownSymbol v) => Patt path '[v] stratum
  PVar :: (KnownSymbol v) => Patt path '[v] stratum
  --PAtt :: Pat stratum -> Pat stratum -> Pat stratum
  PWildcardd :: Patt top '[] stratum
  PEqq :: Patt (Leq path) binds stratum -> Patt (Req path) nobinds stratum -> Patt path binds stratum

deriving instance Show (Patt top binds stratum)

-- Paths through the "pat/exp" tree
data Path = Root | Leq Path | Req Path | Lapp Path | Rapp Path

problemVar :: Path -> Maybe String
problemVar Root = Just "naked expression at top level"
problemVar (Req Root) = Nothing
problemVar (leftSpine -> True) = Nothing
problemVar (Lapp (patternSide -> True)) = Just "pattern var in function position"
problemVar _ = Nothing

patternSide :: Path -> Bool
patternSide (Lapp p) = patternSide p
patternSide (Rapp p) = patternSide p
patternSide (Leq _) = True
patternSide _ = False

leftSpine :: Path -> Bool
leftSpine (Leq Root) = True
leftSpine (Lapp p) = leftSpine p
leftSpine _ = False

class ValidVarPath (varpath :: Path )

--instance ValidVarPath Root
instance ValidVarPath (Req Root)
instance (LeftSpine p ~ True) => ValidVarPath p
instance (PatternSide p ~ False) => ValidVarPath (Lapp p)
--instance ValidVarPath (Req Root)

type family PatternSide (p :: Path) :: Bool where
  PatternSide (Lapp p) = PatternSide p
  PatternSide (Rapp p) = PatternSide p
  PatternSide (Leq p) = True
  PatternSide p = False

type family LeftSpine (p :: Path) :: Bool where
  LeftSpine (Leq Root) = True
  LeftSpine (Lapp p) = LeftSpine p
  LeftSpine p = False

{-
type family And (l :: Bool) (r :: Bool) :: Bool where
  And True r = r
  And l r = False

type family Or (l :: Bool) (r :: Bool) :: Bool where
  Or False r = r
  Or l r = True
-}
type family Append (l :: [Symbol]) (r :: [Symbol]) :: [Symbol] where
  Append '[] r = r
  Append (h ': t) r = h ': Append t r

p1 :: Patt (Req Root) '["a"] Z
p1 = PAppp (PConstructor "Just") (PVar :: Patt (Rapp (Req Root)) '["a"] Z)

p2 :: Patt (Leq Root) '[] Z
p2 = PAppp (PConstructor "Just") (PConstructor "True")

p3 :: Patt (Leq Root) '["foo", "a"] Z
p3 = PAppp (PVar :: Patt (Lapp (Leq Root)) '["foo"] Z) (PVar :: Patt (Rapp (Leq Root)) '["a"] Z)

p4 :: Patt Root '["foo", "a"] Z
p4 = PEqq p3 p1


data Signature (stratum :: Nat) where
  Signature :: String -> Typ (S stratum) -> Signature stratum

deriving instance Show (Signature stratum)

data DefData (stratum :: Nat) where
  DefData :: Signature (S stratum) -> [Signature stratum `Either` DefData stratum] -> DefData (S stratum)

deriving instance Show (DefData stratum)

newtype CharParse (stratum :: Nat) a = CP (String -> Maybe (a, String))

parseLevel :: Nat' s -> CharParse s ()
parseLevel (S' (S' Z')) = reserved "0" <|> return () -- FIXME
parseLevel (S' (S' l)) = reserved $ show $ lev l -- FIXME
   where lev :: Nat' n -> Int
         lev Z' = 0
         lev (S' l) = 1 + lev l
parseLevel _ = failure

cP = token . CP

instance P CharParse where
  type State CharParse = String
  peek p = CP $ \s -> case runCP p s of Just a -> Just (a, s); _ -> Nothing
  accept = CP . const . return . ((),)

  star :: forall s . KnownStratum s => CharParse s ()
  star = cP $ \s -> do ('*' : rest) <- return s -- \do ('*' : rest)
                       runCP (parseLevel (stratum :: Nat' s)) rest

  reserved w = cP $ \s -> do guard $ and $ zipWith (==) w s
                             guard . not . null $ drop (length w - 1) s -- TODO: peek not alnum
                             return ((), drop (length w) s)

  operator o = cP $ \s -> do guard $ and $ zipWith (==) o s
                             guard . not . null $ drop (length o - 1) s -- TODO: peek not symbol
                             return ((), drop (length o) s)

  identifier = cP $ \s -> do (lead : rest) <- return s
                             guard $ isLower lead
                             let (more, rest') = span isAlphaNum rest
                             let id = lead : more
                             guard . not $ id `elem` ["data", "where"]
                             return $ (id, rest')

  constructor = cP $ \s -> do (lead : rest) <- return s
                              guard $ isUpper lead
                              let (more, rest') = span (liftA2 (||) isLower isUpper) rest
                              return $ (lead : more, rest')

  failure = CP $ const Nothing
  ascend (CP f) = CP f
  descend (CP f) = CP f
  token p = id <$> p <* many space
    where space = CP $ \s -> do ((isSpace -> True) : rest) <- return s
                                return ((), rest)


instance Functor (CharParse stratum) where
  fmap f (CP p) = CP $ fmap (\(a, str) -> (f a, str)) . p

instance Applicative (CharParse stratum) where
  pure = return
  (<*>) = ap

instance Alternative (CharParse stratum) where
  empty = failure
  CP l <|> CP r = CP $ \s -> case (l s, r s) of
                              (l, Nothing) -> l
                              (l@(Just (_, lrest)), Just (_, rrest)) | length lrest <= length rrest -> l
                              (_, r) -> r

instance Monad (CharParse stratum) where
  return a = CP $ return . (a,)
  (CP f) >>= c = CP $ \s -> do (a, rest) <- f s -- do (f -> Just (a, rest)) <- return s -- \do f -> (a, rest)
                               runCP (c a) rest

instance MonadPlus (CharParse stratum) where
  mzero = failure
  mplus = (<|>)

runCP (CP f) = f

runCP' :: proxy stratum -> CharParse stratum (c stratum) -> String -> Maybe ((c stratum), String)
runCP' _ (CP f) = f


