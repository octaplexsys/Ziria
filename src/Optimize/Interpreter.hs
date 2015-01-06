{-
   Copyright (c) Microsoft Corporation
   All rights reserved.

   Licensed under the Apache License, Version 2.0 (the ""License""); you
   may not use this file except in compliance with the License. You may
   obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR
   CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT
   LIMITATION ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR
   A PARTICULAR PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.

   See the Apache Version 2.0 License for specific language governing
   permissions and limitations under the License.
-}
-- | Interpreter
--
-- NOTES:
--
-- * Free variables from the environment can be read but not written to -- when
--   the code has side effects (that is, writes to free variables) we fail to
--   evaluate the code.
-- * We index variables by their `uniqId`
-- * We assume type correct terms. Type incorrect terms will yield runtime
--   exceptions.
{-# OPTIONS_GHC -Wall -Wwarn #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Interpreter (
    -- * Interpretations of expressions
    Prints
  , evalPartial
  , evalFull
  , evalInt
  , evalBool
  , provable
  , implies
    -- * Interpretation of source expressions
  , evalSrcInt
  , evalSrcBool
    -- ** Convenience
  , eNot
  , eOr
  , eTrue
  , eFalse
  ) where

import Control.Applicative
import Control.Monad.Error
import Control.Monad.RWS hiding (Any)
import Data.Bits hiding (bit)
import Data.Int
import Data.List (intercalate)
import Data.Map (Map)
import Data.Maybe
import Data.Set (Set)
import GHC.Prim (Any)
import Outputable
import System.IO.Unsafe (unsafePerformIO)
import Text.Parsec.Pos (SourcePos)
import Unsafe.Coerce (unsafeCoerce)
import qualified Data.Map as Map
import qualified Data.Set as Set

import AstExpr
import AstUnlabelled
import CtExpr (ctExp)
import GenSym (initGenSym)
import TcMonad (runTcM')
import Typecheck (tyCheckExpr)

{-------------------------------------------------------------------------------
  Top-level API
-------------------------------------------------------------------------------}

type Prints = String

-- | Interpreter mode
--
-- Note that only `EvalApprox` is non-deterministic; `EvalPartial` and
-- `EvalFull` both result in precisely one answer (which may be an error).
data EvalMode =
    -- | Partial evaluation
    --
    -- Free variables will be left unchanged, where possible.
    --
    -- > a + 2 * 3 ~~> a + 6
    EvalPartial

    -- | Full evaluation
    --
    -- Free variables in the expression will result in an error.
  | EvalFull

    -- | Approximation
    --
    -- For use in satisfiability checking.
    --
    -- > if a then 1 else 2 ~~> [1, 2]
  | EvalApprox

-- | (Partial) evaluation of an expression
evalPartial :: Exp -> (Either String Exp, Prints)
evalPartial e = head' $ evalEval (interpret e) EvalPartial initState
  where
    head' []    = error "evalPartial: unexpected empty list"
    head' (x:_) = x

-- | (Full) evaluation of an expression
--
-- The result of full evaluation should either be an EVal, EValArr or EStruct.
evalFull :: Exp -> (Either String Exp, Prints)
evalFull e = head' $ evalEval (interpret e) EvalFull initState
  where
    head' []    = error "evalFull: unexpected empty list"
    head' (x:_) = x

-- | Evaluate an expression to an integer
evalInt :: Exp -> (Either String Integer, Prints)
evalInt e = case evalFull e of
  (Left err, prints)              -> (Left err, prints)
  (Right e', prints)
    | EVal _ (VInt i) <- unExp e' -> (Right i, prints)
    | otherwise                   -> (Left "Not an integer", prints)

-- | Evaluate an expression to a boolean
evalBool :: Exp -> (Either String Bool, Prints)
evalBool e = case evalFull e of
  (Left err, prints)               -> (Left err, prints)
  (Right e', prints)
    | EVal _ (VBool b) <- unExp e' -> (Right b, prints)
    | otherwise                    -> (Left "Not an integer", prints)

-- | Evaluate a source expression to an integer
--
-- The evaluator needs type information to work. When we are evaluating
-- source expressions, it's easier to type check the expression and then
-- evaluate it, rather than parametrize the type checker so that it can work
-- with source expressions directly.
--
-- The type checker runs in the I/O monad to generate symbols. However, if we
-- are evaluating a standalone source expression to an integer, then the
-- evaluation is independent of the symbols we pick. Hence, it is sound to use
-- unsafePerformIO here.
evalSrcInt :: SrcExp -> (Either String Integer, Prints)
evalSrcInt e = unsafePerformIO $ do
    sym <- initGenSym "evalSrcInt"
    me' <- runTcM' (tyCheckExpr e) sym
    case me' of
      Left  err     -> return (Left ("Type error: " ++ show err), [])
      Right (e', _) -> return $ evalInt e'

-- | Evaluate a source expression to a boolean
--
-- See comments for `evalSrcInt`.
evalSrcBool :: SrcExp -> (Either String Bool, Prints)
evalSrcBool e = unsafePerformIO $ do
    sym <- initGenSym "evalSrcBool"
    me' <- runTcM' (tyCheckExpr e) sym
    case me' of
      Left  err     -> return (Left ("Type error: " ++ show err), [])
      Right (e', _) -> return $ evalBool e'

-- | (Full) evaluation of expressions, guessing values for boolean expressions
approximate :: Exp -> [Exp]
approximate e =
    [ e'
    | (Right e', _prints) <- evalEval (interpret e) EvalApprox initState
    ]

-- | Satisfiability check for expressions of type Bool
--
-- NOTE: This only makes sense for expressions of type Bool and should not be
-- called on other expressions.
satisfiable :: Exp -> Bool
satisfiable = any isTrue . approximate
  where
    isTrue :: Exp -> Bool
    isTrue e | EVal TBool (VBool True) <- unExp e = True
    isTrue _                                      = False

-- | Provability of boolean expressions
--
-- NOTE: This only makes sense for expressions of type Bool and should not be
-- called on other expressions.
provable :: Exp -> Bool
provable = not . satisfiable . eNot

-- | Does one expression imply another?
--
-- NOTE: This only makes sense for expressions of type Bool and should not be
-- called on other expressions.
implies :: Exp -> Exp -> Bool
implies a b = provable (eNot a `eOr` b)

{-------------------------------------------------------------------------------
  Interpreter monad
-------------------------------------------------------------------------------}

data EvalState = EvalState {
    -- Locally bound variables (let or letref)
    evalMemory :: Map String Exp

    -- Guesses made during satisfiability checking for generic boolean-valued
    -- expressions
  , evalGuessesBool :: Map Exp Exp

    -- Guesses made about the range of integer-valued expressions
  , evalGuessesInt :: Map Exp IntDomain
  }
  deriving Show

initState :: EvalState
initState = EvalState {
    evalMemory      = Map.empty
  , evalGuessesBool = Map.empty
  , evalGuessesInt  = Map.empty
  }

-- | The evaluator monad
--
-- The evaluator monad keeps track of a lot of things:
--
-- 1. ErrorT: Runtime errors such as out-of-bound array indices
-- 2. ReaderT: Configuration
-- 3. State: Locally bound vars and writes to locally bound vars
-- 4. WriterT: Any debug prints executed by the program
-- 5. []: Non-determinism arising from guessing values
newtype Eval a = Eval {
      unEval :: ErrorT String (RWST EvalMode Prints EvalState []) a
    }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadError String
           )

-- We don't want the MonadPlus instance from ErrorT
-- (in fact, I don't think ErrorT should even introduce a MonadPlus instance..)
instance MonadPlus Eval where
  mzero       = mkEval $ \_mode _st -> []
  f `mplus` g = mkEval $ \mode st -> runEval f mode st <|> runEval g mode st

instance Alternative Eval where
  empty = mzero
  (<|>) = mplus

runEval :: Eval a -> EvalMode -> EvalState -> [(Either String a, EvalState, Prints)]
runEval = runRWST . runErrorT . unEval

evalEval :: Eval a -> EvalMode -> EvalState -> [(Either String a, Prints)]
evalEval = evalRWST . runErrorT . unEval

mkEval :: (EvalMode -> EvalState -> [(Either String a, EvalState, Prints)]) -> Eval a
mkEval = Eval . ErrorT . RWST

readVar :: String -> Eval (Maybe Exp)
readVar x = Eval $ gets $ Map.lookup x . evalMemory

extendScope :: String -> Exp -> Eval a -> Eval a
extendScope x v (Eval act) = Eval $ do
    modify $ \st -> st { evalMemory = Map.insert x v (evalMemory st) }
    a <- act
    modify $ \st -> st { evalMemory = Map.delete x (evalMemory st) }
    return a

writeVar :: String -> Exp -> Eval ()
writeVar x v = Eval $ do
    st <- get
    -- A write to a non-locally defined variable is _always_ an error, whether
    -- we are doing partial evaluation or not.
    case Map.insertLookupWithKey (\_ new _ -> new) x v (evalMemory st) of
      (Just _, mem') -> put st { evalMemory = mem' }
      (Nothing, _)   -> throwError $ "Variable " ++ x ++ " not in scope"

getMode :: Eval EvalMode
getMode = Eval ask

partiallyEvaluated :: a -> Eval a
partiallyEvaluated x = do
  mode <- getMode
  case mode of
    EvalPartial -> return x
    EvalFull    -> throwError "Free variables"
    EvalApprox  -> mzero

cannotEvaluate :: String -> Eval a
cannotEvaluate msg = do
  mode <- getMode
  case mode of
    EvalPartial -> throwError msg
    EvalFull    -> throwError "Free variables"
    EvalApprox  -> mzero

logPrint :: Bool -> String -> Eval ()
logPrint True  str = Eval $ tell (str ++ "\n")
logPrint False str = Eval $ tell str

-- | Run the guess algorithm if we could not fully evaluate the expression.
--
-- This does NOT execute the error handler for errors thrown by throwError.
guessIfUnevaluated :: (Exp -> Eval Exp) -> (Exp -> Eval Exp)
guessIfUnevaluated f e = mkEval $ \mode st ->
  case runEval (f e) mode st of
    [] | EvalApprox <- mode -> runEval (guess e) mode st
    result                  -> result

{-------------------------------------------------------------------------------
  The interpreter proper
-------------------------------------------------------------------------------}

-- | Interpreter for the expression language

interpret :: Exp -> Eval Exp
interpret e = guessIfUnevaluated (go . unExp) e
  where
    go :: Exp0 -> Eval Exp

    -- Values

    go (EVal _ _) = return e

    -- Arrays

    go (EValArr elems) = do
      elems' <- mapM interpret elems
      return $ eValArr eloc elems'
    go (EArrRead arr ix li) = do
      arr' <- interpret arr
      ix'  <- interpret ix
      case (unExp arr', unExp ix', li) of
        -- Both array and index in normal form: array index
        (EValArr vs, EVal _ (VInt i), LISingleton) ->
          case splitListAt i vs of
            Just (_, y, _) -> return y
            Nothing        -> throwError $ "Out of bounds"
        -- Both array and index in normal form: array slice
        (EValArr vs, EVal _ (VInt i), LILength len) ->
          case sliceListAt i len vs of
            Just (_, ys, _) -> return $ eValArr eloc ys
            Nothing         -> throwError $ "Out of bounds"
        -- Not in normal form. Leave uninterpreted
        _ ->
          partiallyEvaluated $ eArrRead eloc arr' ix' li

    -- Array permutation

    go (EBPerm _ _) =
      throwError "TODO: EBPerm not yet supported"

    -- Structs

    go (EStruct ty fields) = do
      let interpretField (fldName, fld) = do
            fld' <- interpret fld
            return (fldName, fld')
      fields' <- mapM interpretField fields
      return $ eStruct eloc ty fields'
    go (EProj struct fld) = do
      struct' <- interpret struct
      case unExp struct' of
        -- In normal form
        EStruct _ fields ->
          case splitListOn ((== fld) . fst) fields of
            Just (_, (_, y), _) -> return y
            Nothing             -> throwError $ "Unknown field"
        -- Not in normal form
        _ ->
          partiallyEvaluated $ eProj eloc struct' fld

    -- Simple operators

    go (EUnOp  op a) = do
      a' <- interpret a
      applyUnOp eloc op a'
    go (EBinOp op a b) = do
      a' <- interpret a
      b' <- interpret b
      applyBinOp eloc op a' b'

    -- Special case for force-inlining
    --
    -- (This is necessary because if the expression has side effects we cannot
    -- evaluate it strictly when force-inlining is specified)

    go (ELet nm ForceInline e1 e2) =
      interpret $ substExp [] [(nm,e1)] e2

    -- Variables

    go (EVar x) = do
      mv <- readVar (uniqId x)
      case mv of
        Just v  -> return v
        Nothing -> partiallyEvaluated $ eVar eloc x
    go (ELet x _ e1  e2) = do
      v <- interpret e1
      extendScope (uniqId x) v $ interpret e2
    go (ELetRef x (Just e1) e2) = do
      v <- interpret e1
      extendScope (uniqId x) v $ interpret e2
    go (ELetRef x Nothing e2) = do
      let v = initialExp eloc (nameTyp x)
      extendScope (uniqId x) v $ interpret e2
    go (EAssign lhs rhs) =
      assign eloc lhs rhs
    go (EArrWrite arr ix len rhs) =
      assign eloc (eArrRead eloc arr ix len) rhs

    -- Control flow

    go (ESeq e1 e2) =
      interpret e1 >> interpret e2
    go (EIter _ _ _ _) =
      throwError "EIter unsupported"
    go (EFor _ui x start len body) = do
      start' <- interpret start
      len'   <- interpret len
      case (unExp start', unExp len') of
        -- Start and length both in normal form
        (EVal ty (VInt start''), EVal _ (VInt len'')) -> do
          extendScope (uniqId x) (error "Not yet assigned") $
            forM_ [start'' .. start'' + len'' - 1] $ \i -> do
              void $ assign eloc (eVar eloc x) (eVal eloc ty (VInt i))
              void $ interpret body
          return $ eVal eloc TUnit VUnit
        -- Bounds not in normal form
        _ ->
          cannotEvaluate "Partial evaluation not supported for control flow"
    go (EWhile cond body) = do
      let loop = do
            cond' <- interpret cond
            case unExp cond' of
              EVal _ (VBool b) ->
                if b then interpret body >> loop
                     else return $ eVal eloc TUnit VUnit
              -- Condition not in normal form
              _ ->
                cannotEvaluate "Partial evaluation not supported for control flow"
      loop
    go (EIf cond iftrue iffalse) = do
      cond' <- interpret cond
      case unExp cond' of
        EVal _ (VBool b) ->
          interpret (if b then iftrue else iffalse)
        -- Condition not in normal form
        _ ->
          cannotEvaluate "Partial evaluation not supported for control flow"

    -- Functions (currently unsupported)

    go (ECall _fn _args) =
      throwError "Function calls unsupported"

    -- Misc

    go (EPrint newline e1) = do
      e1' <- interpret e1
      logPrint newline (pretty e1')
      return $ eVal eloc TUnit VUnit
    go (EError _ str) =
      throwError $ "EError: " ++ str
    go (ELUT _ e') =
      interpret e'

    eloc :: Maybe SourcePos
    eloc = expLoc e

-- | Assignment
--
-- (Auxiliary to `interpret`)
assign :: Maybe SourcePos -> Exp -> Exp -> Eval Exp
assign p lhs rhs = do
    rhs' <- interpret rhs
    deref (unExp lhs) (\_ -> return rhs')
    return $ eVal p TUnit VUnit
  where
    -- `deref` gives the semantics of a derefercing expression by describing
    -- how a function on values is interpreted as a state update
    deref :: Exp0 -> (Exp -> Eval Exp) -> Eval ()
    deref (EVar x) f = do
      mv <- readVar (uniqId x)
      case mv of
        Just v  -> writeVar (uniqId x) =<< f v
        Nothing -> throwError $ "assign: variable " ++ pretty x ++ " not in scope"
    deref (EArrRead arr ix LISingleton) f = do
      ix' <- interpret ix
      deref (unExp arr) $ updateArray f ix'
    deref (EArrRead arr ix (LILength n)) f = do
      ix' <- interpret ix
      deref (unExp arr) $ updateSlice f ix' n
    deref (EProj struct fld) f = do
      deref (unExp struct) $ updateStruct f fld
    deref _ _ =
      error "Invalid derefencing expression"

    updateArray :: (Exp -> Eval Exp) -> Exp -> (Exp -> Eval Exp)
    updateArray f ix arr =
        case (unExp arr, unExp ix) of
          -- Array and index in normal form
          (EValArr vs, EVal _ (VInt i)) ->
            case splitListAt i vs of
              Just (xs, y, zs) -> do
                y' <- f y
                return $ eValArr eloc (xs ++ [y'] ++ zs)
              Nothing ->
                throwError "Out of bounds"
          -- Not in normal form
          _ ->
            cannotEvaluate "Partial assignment for arrays not supported"
      where
        eloc = expLoc arr

    updateSlice :: (Exp -> Eval Exp) -> Exp -> Int -> (Exp -> Eval Exp)
    updateSlice f ix len arr =
        case (unExp arr, unExp ix) of
          -- Array and index in normal form
          (EValArr vs, EVal _ (VInt i)) ->
            case sliceListAt i len vs of
              Just (xs, ys, zs) -> do
                let slice = eValArr eloc ys
                slice' <- f slice
                case unExp slice' of
                  EValArr ys' -> return $ eValArr eloc (xs ++ ys' ++ zs)
                  _           -> error "Cannot happen"
              Nothing ->
                throwError "Out of bounds"
          -- Not in normal form
          _ ->
            cannotEvaluate "Partial assignment for arrays not supported"
      where
        eloc = expLoc arr

    updateStruct :: (Exp -> Eval Exp) -> FldName -> (Exp -> Eval Exp)
    updateStruct f fld struct =
        case unExp struct of
          -- Struct in normal form
          EStruct ty flds ->
            case splitListOn ((== fld) . fst) flds of
              Just (xs, (_fld, y), zs) -> do
                y' <- f y
                return $ eStruct eloc ty (xs ++ [(fld, y')] ++ zs)
              Nothing ->
                throwError "Unknown field"
          -- Not in normal form
          _ ->
            cannotEvaluate "Partial assignment for structs not supported"
      where
        eloc = expLoc struct

-- | The runtime currently leaves the initial value for unassigned variables
-- unspecified (https://github.com/dimitriv/Ziria/issues/79). This means that
-- we are free to specify whatever we wish in the interpret -- here we pick
-- sensible defaults.
initialExp :: Maybe SourcePos -> Ty -> Exp
initialExp p ty =
    case ty of
      TArray (NVar _)    _   -> error "initialExp: length variable"
      TArray (Literal n) ty' -> eValArr p    $ replicate n (initialExp p ty')
      TStruct _ fields       -> eStruct p ty $ map initialField fields
      TUnit                  -> eVal    p ty $ VUnit
      TBit                   -> eVal    p ty $ VBit    False
      TBool                  -> eVal    p ty $ VBool   False
      TString                -> eVal    p ty $ VString ""
      TDouble                -> eVal    p ty $ VDouble 0
      (TInt _)               -> eVal    p ty $ VInt    0
      _                      -> error $ "initialExp: unsupported " ++ pretty ty
  where
    initialField :: (FldName, Ty) -> (FldName, Exp)
    initialField (fldName, ty') = (fldName, initialExp p ty')

-- | Smart constructor for binary operators
applyBinOp :: Maybe SourcePos -> BinOp -> Exp -> Exp -> Eval Exp
applyBinOp p op a b =
    let evald = do a' <- expToDyn a
                   b' <- expToDyn b
                   dynToExp p $ zBinOp op `dynApply` a' `dynApply` b'
    in case evald of
         Just e  -> return $ e
         Nothing -> partiallyEvaluated $ eBinOp p op a b

-- | Smart constructor for unary operators
applyUnOp :: Maybe SourcePos -> UnOp -> Exp -> Eval Exp
applyUnOp p ALength a =
    case unExp a of
      EValArr vals -> return $ eVal p tint32 (VInt (toInteger (length vals)))
      _            -> partiallyEvaluated $ eUnOp p ALength a
applyUnOp p op a =
    let evald = do a' <- expToDyn a
                   dynToExp p $ zUnOp op `dynApply` a'
    in case evald of
         Just e  -> return $ e
         Nothing -> partiallyEvaluated $ eUnOp p op a

{-------------------------------------------------------------------------------
  Since the interpreter works with dynamically typed values, we provide some
  infrastructure here for working with such values. This mirrors the standard
  definition of (old) Typeable and Dynamic, but using Ziria's own types and
  with support for ad-hoc polymorphism.
-------------------------------------------------------------------------------}

class Typeable a where
  typeOf :: a -> Ty

-- | Avoids confusion between booleans and bits
newtype Bit = Bit { bit :: Bool }
  deriving (Eq, Ord, Enum, Show, Bits)

instance Typeable ()     where typeOf _ = TUnit
instance Typeable Bit    where typeOf _ = TBit
instance Typeable Bool   where typeOf _ = TBool
instance Typeable Int8   where typeOf _ = TInt BW8
instance Typeable Int16  where typeOf _ = TInt BW16
instance Typeable Int32  where typeOf _ = TInt BW32
instance Typeable Int64  where typeOf _ = TInt BW64
instance Typeable Double where typeOf _ = TDouble
instance Typeable String where typeOf _ = TString

instance (Typeable a, Typeable b) => Typeable (a -> b) where
  typeOf (_ :: a -> b) = TArrow [typeOf (undefined :: a)]
                                (typeOf (undefined :: b))

data Dynamic = Dynamic [(Ty, Any)]

instance Show Dynamic where
  show (Dynamic vs) =
      "Dynamic [" ++ intercalate "," (map (uncurry aux) vs) ++ "]"
    where
      aux :: Ty -> Any -> String
      aux ty val = case dynToExp' Nothing ty val of
                     Just e  -> pretty e      ++ " :: " ++ pretty ty
                     Nothing -> "<<dynamic>>" ++ " :: " ++ pretty ty

toDyn :: Typeable a => a -> Dynamic
toDyn x = Dynamic [(typeOf x, unsafeCoerce x)]

dynApply :: Dynamic -> Dynamic -> Dynamic
dynApply (Dynamic fs) (Dynamic xs) = Dynamic
    [ (yty, unsafeCoerce f x)
    | (fty, f) <- fs
    , (xty, x) <- xs
    , Just yty <- [funResult fty xty]
    ]
  where
    funResult :: Ty -> Ty -> Maybe Ty
    funResult (TArrow [a] b) a' | a == a' = Just $ b
    funResult _ _ = Nothing

instance Monoid Dynamic where
  mempty = Dynamic []
  Dynamic xs `mappend` Dynamic ys = Dynamic (xs ++ ys)

{-------------------------------------------------------------------------------
  Define the semantics of Ziria operators using the dynamic typing
  infrastructure developed in the previous section.
-------------------------------------------------------------------------------}

zNum2 :: (forall a. Num a => a -> a -> a) -> Dynamic
zNum2 f = mconcat [
      toDyn (f :: Int8   -> Int8   -> Int8)
    , toDyn (f :: Int16  -> Int16  -> Int16)
    , toDyn (f :: Int32  -> Int32  -> Int32)
    , toDyn (f :: Int64  -> Int64  -> Int64)
    , toDyn (f :: Double -> Double -> Double)
    ]

zIntegral :: (forall a. Integral a => a -> a -> a) -> Dynamic
zIntegral f = mconcat [
      toDyn (f :: Int8  -> Int8  -> Int8)
    , toDyn (f :: Int16 -> Int16 -> Int16)
    , toDyn (f :: Int32 -> Int32 -> Int32)
    , toDyn (f :: Int64 -> Int64 -> Int64)
    ]

zFloating :: (forall a. Floating a => a -> a -> a) -> Dynamic
zFloating f = mconcat [
      toDyn (f :: Double -> Double -> Double)
    ]

zBits2 :: (forall a. Bits a => a -> a -> a) -> Dynamic
zBits2 f = mconcat [
      toDyn (f :: Bit   -> Bit   -> Bit)
    , toDyn (f :: Bool  -> Bool  -> Bool)
    , toDyn (f :: Int8  -> Int8  -> Int8)
    , toDyn (f :: Int16 -> Int16 -> Int16)
    , toDyn (f :: Int32 -> Int32 -> Int32)
    , toDyn (f :: Int64 -> Int64 -> Int64)
    ]

zShift :: (forall a. Bits a => a -> Int -> a) -> Dynamic
zShift f = mconcat [
      toDyn (f' :: Int8  -> Int8  -> Int8)
    , toDyn (f' :: Int8  -> Int16 -> Int8)
    , toDyn (f' :: Int8  -> Int32 -> Int8)
    , toDyn (f' :: Int8  -> Int64 -> Int8)
    , toDyn (f' :: Int16 -> Int8  -> Int16)
    , toDyn (f' :: Int16 -> Int16 -> Int16)
    , toDyn (f' :: Int16 -> Int32 -> Int16)
    , toDyn (f' :: Int16 -> Int64 -> Int16)
    , toDyn (f' :: Int32 -> Int8  -> Int32)
    , toDyn (f' :: Int32 -> Int16 -> Int32)
    , toDyn (f' :: Int32 -> Int32 -> Int32)
    , toDyn (f' :: Int32 -> Int64 -> Int32)
    , toDyn (f' :: Int64 -> Int8  -> Int64)
    , toDyn (f' :: Int64 -> Int16 -> Int64)
    , toDyn (f' :: Int64 -> Int32 -> Int64)
    , toDyn (f' :: Int64 -> Int64 -> Int64)
    ]
  where
    f' :: (Bits a, Integral b) => a -> b -> a
    f' x i = f x (fromIntegral i)

zOrd :: (forall a. Ord a => a -> a -> Bool) -> Dynamic
zOrd f = mconcat [
      toDyn (f :: ()     -> ()     -> Bool)
    , toDyn (f :: Bit    -> Bit    -> Bool)
    , toDyn (f :: Bool   -> Bool   -> Bool)
    , toDyn (f :: Int8   -> Int8   -> Bool)
    , toDyn (f :: Int16  -> Int16  -> Bool)
    , toDyn (f :: Int32  -> Int32  -> Bool)
    , toDyn (f :: Int64  -> Int64  -> Bool)
    , toDyn (f :: Double -> Double -> Bool)
    , toDyn (f :: String -> String -> Bool)
    ]

zBinOp :: BinOp -> Dynamic
zBinOp Add   = zNum2 (+)
zBinOp Sub   = zNum2 (-)
zBinOp Mult  = zNum2 (*)
zBinOp Div   = zIntegral quot <> zFloating (/)
zBinOp Rem   = zIntegral rem
zBinOp Expon = zIntegral (^) <> zFloating (**)
zBinOp ShL   = zShift shift
zBinOp ShR   = zShift (\x -> shift x . negate)
zBinOp BwAnd = zBits2 (.&.)
zBinOp BwOr  = zBits2 (.|.)
zBinOp BwXor = zBits2 xor
zBinOp Eq    = zOrd (==)
zBinOp Neq   = zOrd (/=)
zBinOp Lt    = zOrd (<)
zBinOp Gt    = zOrd (>)
zBinOp Leq   = zOrd (<=)
zBinOp Geq   = zOrd (>=)
zBinOp And   = toDyn (&&)
zBinOp Or    = toDyn (||)

{-------------------------------------------------------------------------------
  Similar for unary operators
-------------------------------------------------------------------------------}

zNum1 :: (forall a. Num a => a -> a) -> Dynamic
zNum1 f = mconcat [
      toDyn (f :: Int8   -> Int8)
    , toDyn (f :: Int16  -> Int16)
    , toDyn (f :: Int32  -> Int32)
    , toDyn (f :: Int64  -> Int64)
    , toDyn (f :: Double -> Double)
    ]

zBits1 :: (forall a. Bits a => a -> a) -> Dynamic
zBits1 f = mconcat [
      toDyn (f :: Bit   -> Bit)
    , toDyn (f :: Bool  -> Bool)
    , toDyn (f :: Int8  -> Int8)
    , toDyn (f :: Int16 -> Int16)
    , toDyn (f :: Int32 -> Int32)
    , toDyn (f :: Int64 -> Int64)
    ]

zCast :: Typeable a
      => Maybe (()     -> a)
      -> Maybe (Bit    -> a)
      -> Maybe (Bool   -> a)
      -> Maybe (Int8   -> a)
      -> Maybe (Int16  -> a)
      -> Maybe (Int32  -> a)
      -> Maybe (Int64  -> a)
      -> Maybe (Double -> a)
      -> Maybe (String -> a)
      -> Dynamic
zCast fUnit fBit fBool fInt8 fInt16 fInt32 fInt64 fDouble fString =
    mconcat . catMaybes $ [
        fmap toDyn fUnit
      , fmap toDyn fBit
      , fmap toDyn fBool
      , fmap toDyn fInt8
      , fmap toDyn fInt16
      , fmap toDyn fInt32
      , fmap toDyn fInt64
      , fmap toDyn fDouble
      , fmap toDyn fString
      ]

-- | Semantics for unary operators
--
-- TODO: The matrix for cast may be incomplete
zUnOp :: UnOp -> Dynamic
zUnOp NatExp    = error "NatExp not implemented"
zUnOp Neg       = zNum1 negate
zUnOp Not       = toDyn not
zUnOp BwNeg     = zBits1 complement
zUnOp ALength   = error "zUnOp: ALength is polymorphic"
zUnOp (Cast ty) = case ty of
            -- Source: ()          Bit         Bool        Int8        Int16       Int32       Int64       Double       String
    TUnit     -> zCast (Just id)   (Just cu)   (Just cu)   (Just cu)   (Just cu)   (Just cu)   (Just cu)   (Just cu)    (Just cu)
    TBit      -> zCast Nothing     (Just id)   (Just Bit)  Nothing     Nothing     Nothing     Nothing     Nothing      Nothing
    TBool     -> zCast Nothing     (Just bit)  (Just id)   Nothing     Nothing     Nothing     Nothing     Nothing      Nothing
    TInt BW8  -> zCast Nothing     (Just ei)   (Just ei)   (Just id)   (Just fi)   (Just fi)   (Just fi)   (Just round) Nothing
    TInt BW16 -> zCast Nothing     (Just ei)   (Just ei)   (Just fi)   (Just id)   (Just fi)   (Just fi)   (Just round) Nothing
    TInt BW32 -> zCast Nothing     (Just ei)   (Just ei)   (Just fi)   (Just fi)   (Just id)   (Just fi)   (Just round) Nothing
    TInt BW64 -> zCast Nothing     (Just ei)   (Just ei)   (Just fi)   (Just fi)   (Just fi)   (Just id)   (Just round) Nothing
    TDouble   -> zCast Nothing     Nothing     Nothing     (Just fi)   (Just fi)   (Just fi)   (Just fi)   (Just id)    Nothing
    TString   -> zCast (Just show) (Just show) (Just show) (Just show) (Just show) (Just show) (Just show) (Just show)  (Just id)
    _         -> error "zUnOp: Invalid target type"
  where
    cu :: a -> ()
    cu = const ()

    ei :: (Enum a, Num b) => a -> b
    ei = fromIntegral . fromEnum

    fi :: (Integral a, Num b) => a -> b
    fi = fromIntegral

{-------------------------------------------------------------------------------
  Conversion between expressions and dynamic values
-------------------------------------------------------------------------------}

expToDyn :: Exp -> Maybe Dynamic
expToDyn e
  | EVal TUnit       VUnit       <- unExp e = Just $ toDyn ()
  | EVal TBit        (VBit b)    <- unExp e = Just $ toDyn (Bit b)
  | EVal TBool       (VBool b)   <- unExp e = Just $ toDyn b
  | EVal TString     (VString s) <- unExp e = Just $ toDyn s
  | EVal (TInt BW8)  (VInt i)    <- unExp e = Just $ toDyn (fromInteger i :: Int8)
  | EVal (TInt BW16) (VInt i)    <- unExp e = Just $ toDyn (fromInteger i :: Int16)
  | EVal (TInt BW32) (VInt i)    <- unExp e = Just $ toDyn (fromInteger i :: Int32)
  | EVal (TInt BW64) (VInt i)    <- unExp e = Just $ toDyn (fromInteger i :: Int64)
  | EVal TDouble     (VDouble d) <- unExp e = Just $ toDyn d
expToDyn _ = Nothing

dynToExp :: Maybe SourcePos -> Dynamic -> Maybe Exp
dynToExp p (Dynamic [(ty, val)]) = dynToExp' p ty val
dynToExp _ _                     = Nothing

-- | Internal auxiliary
dynToExp' :: Maybe SourcePos -> Ty -> Any -> Maybe Exp
dynToExp' p ty val = do
    val' <- case ty of
              TUnit     -> Just $ VUnit
              TBit      -> Just $ VBit    (bit (unsafeCoerce val))
              TBool     -> Just $ VBool   (unsafeCoerce val)
              TString   -> Just $ VString (unsafeCoerce val)
              TInt BW8  -> Just $ VInt    (toInteger (unsafeCoerce val :: Int8))
              TInt BW16 -> Just $ VInt    (toInteger (unsafeCoerce val :: Int16))
              TInt BW32 -> Just $ VInt    (toInteger (unsafeCoerce val :: Int32))
              TInt BW64 -> Just $ VInt    (toInteger (unsafeCoerce val :: Int64))
              TDouble   -> Just $ VDouble (unsafeCoerce val)
              _         -> Nothing
    return $ eVal p ty val'

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

splitListAt :: Integer -> [a] -> Maybe ([a], a, [a])
splitListAt = go []
  where
    go _      _ []        = Nothing
    go before 0 (x:after) = Just (reverse before, x, after)
    go before n (x:after) = go (x:before) (n-1) after

-- Slice a list.
--
-- @sliceListAt n len@ isolates a chunk of length @len@ at position @n@.
--
-- > sliceListAt 3 2 [0..9] == Just ([0..2], [3, 4], [5..9])
sliceListAt :: Integer -> Int -> [a] -> Maybe ([a], [a], [a])
sliceListAt = go [] []
  where
    go  before  slice  0  0 after     = Just (reverse before, reverse slice, after)
    go _before _slice  0 _n []        = Nothing
    go  before  slice  0  n (x:after) = go before (x:slice) 0 (n-1) after
    go _before _slice _m _n []        = Nothing
    go  before  slice  m  n (x:after) = go (x:before) slice (m-1) n after

splitListOn :: (a -> Bool) -> [a] -> Maybe ([a], a, [a])
splitListOn f = go []
  where
    go _      []                    = Nothing
    go before (x:after) | f x       = Just (reverse before, x, after)
                        | otherwise = go (x:before) after

{-------------------------------------------------------------------------------
  Guessing (for satisfiability checking)
-------------------------------------------------------------------------------}

-- | Guess the value for expressions
--
-- See http://www.well-typed.com/blog/2014/12/simple-smt-solver/ for a
-- discussion of this approach.
guess :: Exp -> Eval Exp
guess e | Just (lhs, op, rhs) <- isComparison e = do
    dom <- previousGuessInt lhs
    let assumeTrue = do
          let dom' = intersectIntDomains dom (mkIntDomain op rhs)
          guard $ not (emptyIntDomain dom')
          recordGuessInt lhs dom'
          return eTrue
        assumeFalse = do
          let dom' = intersectIntDomains dom (mkIntDomain (negBinOp op) rhs)
          guard $ not (emptyIntDomain dom')
          recordGuessInt lhs dom'
          return eFalse
    assumeTrue `mplus` assumeFalse
guess e = do
    previous <- previousGuessBool e
    case previous of
      Just e' -> return e'
      Nothing ->
       case ctExp e of
         TBool -> recordGuessBool e eTrue `mplus` recordGuessBool e eFalse
         ty    -> cannotEvaluate $ "Cannot guess values for type " ++ pretty ty

previousGuessBool :: Exp -> Eval (Maybe Exp)
previousGuessBool e = Eval $
    gets $ Map.lookup (eraseLoc e)
         . evalGuessesBool

recordGuessBool :: Exp -> Exp -> Eval Exp
recordGuessBool e e' = Eval $ do
    st <- get
    put $ st {
        evalGuessesBool = Map.insert (eraseLoc e) e' (evalGuessesBool st)
      }
    return e'

previousGuessInt :: Exp -> Eval IntDomain
previousGuessInt e = Eval $
    gets $ Map.findWithDefault fullIntDomain (eraseLoc e)
         . evalGuessesInt

recordGuessInt :: Exp -> IntDomain -> Eval ()
recordGuessInt e dom = Eval $ do
    st <- get
    put $ st {
        evalGuessesInt = Map.insert (eraseLoc e) dom (evalGuessesInt st)
      }

isComparison :: Exp -> Maybe (Exp, BinOp, Integer)
isComparison e
    | EBinOp op lhs rhs <- unExp e
    , EVal _ (VInt i)   <- unExp rhs
    , op `elem` comparisonOps
    = Just (lhs, op, i)
  where
    comparisonOps = [Eq, Neq, Lt, Gt, Leq, Geq]
isComparison _ = Nothing

negBinOp :: BinOp -> BinOp
negBinOp Eq  = Neq
negBinOp Neq = Eq
negBinOp Lt  = Geq
negBinOp Gt  = Leq
negBinOp Leq = Gt
negBinOp Geq = Lt
negBinOp _   = error "negBinOp: invalid bin op"

{-------------------------------------------------------------------------------
  Integer domains
-------------------------------------------------------------------------------}

-- | Integer domains
--
-- An integer domain describes our current approximation for an integer.  Let
-- @d@ be an integer domain, and @x@ be an integer; then if @x `in` d@..
data IntDomain = IntDomain {
      intDomLower :: Maybe Integer   -- ^ .. @intDomLower d <= x@
    , intDomUpper :: Maybe Integer   -- ^ .. @x <= intDomUpper d@
    , intDomHoles :: Set Integer     -- ^ .. @x `notElem` intDomHoles d@
    }
    deriving (Eq, Show)

fullIntDomain :: IntDomain
fullIntDomain = IntDomain {
      intDomLower = Nothing
    , intDomUpper = Nothing
    , intDomHoles = Set.empty
    }

emptyIntDomain :: IntDomain -> Bool
emptyIntDomain d =
    fromMaybe False $ aux (intDomHoles d) <$> intDomLower d <*> intDomUpper d
  where
    aux holes lo hi = lo > hi || (lo == hi && lo `Set.member` holes)

intersectIntDomains :: IntDomain -> IntDomain -> IntDomain
intersectIntDomains d d' = IntDomain {
      intDomLower = case (intDomLower d, intDomLower d') of
                      (Nothing, Nothing) -> Nothing
                      (Just l,  Nothing) -> Just l
                      (Nothing, Just l') -> Just l'
                      (Just l,  Just l') -> Just (l `max` l')
    , intDomUpper = case (intDomUpper d, intDomUpper d') of
                      (Nothing, Nothing) -> Nothing
                      (Just l,  Nothing) -> Just l
                      (Nothing, Just l') -> Just l'
                      (Just l,  Just l') -> Just (l `min` l')
    , intDomHoles = intDomHoles d `Set.union` intDomHoles d'
    }

mkIntDomain :: BinOp -> Integer -> IntDomain
mkIntDomain Eq  n = IntDomain (Just n)       (Just n)       Set.empty
mkIntDomain Leq n = IntDomain Nothing        (Just n)       Set.empty
mkIntDomain Geq n = IntDomain (Just n)       Nothing        Set.empty
mkIntDomain Lt  n = IntDomain Nothing        (Just (n - 1)) Set.empty
mkIntDomain Gt  n = IntDomain (Just (n + 1)) Nothing        Set.empty
mkIntDomain Neq n = IntDomain Nothing        Nothing        (Set.singleton n)
mkIntDomain _   _ = error "mkIntDomain: Invalid operator"

{-------------------------------------------------------------------------------
  Constructing expressions (for convenience)
-------------------------------------------------------------------------------}

eNot :: Exp -> Exp
eNot e = eUnOp (expLoc e) Not e

eOr :: Exp -> Exp -> Exp
eOr e e' = eBinOp (expLoc e) Or e e'

eTrue, eFalse :: Exp
eTrue  = eVal Nothing TBool (VBool True)
eFalse = eVal Nothing TBool (VBool False)