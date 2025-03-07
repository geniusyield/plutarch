{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}

module Plutarch.Lift (
  -- * Converstion between Plutarch terms and Haskell types
  pconstant,
  plift,
  plift',
  LiftError,

  -- * Define your own conversion
  PConstant (..),
  PLift,
  DerivePConstantDirect (..),
  DerivePConstantViaNewtype (..),

  -- * Internal use
  PUnsafeLiftDecl (..),
) where

import Data.Coerce
import Data.Kind (Type)
import GHC.Stack (HasCallStack)
import Plutarch.Evaluate (evaluateScript)
import Plutarch.Internal (ClosedTerm, PType, Term, compile, punsafeConstantInternal)
import qualified Plutus.V1.Ledger.Scripts as Scripts
import qualified PlutusCore as PLC
import PlutusCore.Builtin (readKnownConstant)

import PlutusCore.Evaluation.Machine.Exception (ErrorWithCause, MachineError)
import qualified UntypedPlutusCore as UPLC


class (PConstant (PLifted p), PConstanted (PLifted p) ~ p) => PUnsafeLiftDecl (p :: PType) where
  type PLifted p :: Type

{- | Class of Haskell types `h` that can be represented as a Plutus core builtin
and converted to a Plutarch type.

The Plutarch type is determined by `PConstanted h`. Its Plutus Core representation is given by `PConstantRepr h`.

This typeclass is closely tied with 'PLift'.
-}
class (PUnsafeLiftDecl (PConstanted h), PLC.DefaultUni `PLC.Includes` PConstantRepr h) => PConstant (h :: Type) where
  type PConstantRepr h :: Type
  type PConstanted h :: PType
  pconstantToRepr :: h -> PConstantRepr h
  pconstantFromRepr :: PConstantRepr h -> Maybe h

{- | Class of Plutarch types `p` that can be converted to/from a Haskell type.

The Haskell type is determined by `PLifted p`.

This typeclass is closely tied with 'PConstant'.
-}
type PLift = PUnsafeLiftDecl

{- | Create a Plutarch-level constant, from a Haskell value.
Example:
> pconstant @PInteger 42
-}
pconstant :: forall p s. PLift p => PLifted p -> Term s p
pconstant x = punsafeConstantInternal $ PLC.someValue @(PConstantRepr (PLifted p)) @PLC.DefaultUni $ pconstantToRepr x

-- | Error during script evaluation.
data LiftError
  = LiftError_ScriptError Scripts.ScriptError
  | LiftError_EvalException (ErrorWithCause (MachineError PLC.DefaultFun) ())
  | LiftError_FromRepr
  | LiftError_WrongRepr
  deriving stock (Eq, Show)

{- | Convert a Plutarch term to the associated Haskell value. Fail otherwise.
This will fully evaluate the arbitrary closed expression, and convert the resulting value.
-}
plift' :: forall p. PUnsafeLiftDecl p => ClosedTerm p -> Either LiftError (PLifted p)
plift' prog = case evaluateScript (compile prog) of
  Right (_, _, Scripts.unScript -> UPLC.Program _ _ term) ->
    case readKnownConstant @_ @(PConstantRepr (PLifted p)) @(MachineError PLC.DefaultFun) Nothing term of
      Right r -> case pconstantFromRepr r of
        Just h -> Right h
        Nothing -> Left LiftError_FromRepr
      Left e -> Left $ LiftError_EvalException e
  Left e -> Left $ LiftError_ScriptError e

-- | Like `plift'` but throws on failure.
plift :: forall p. (HasCallStack, PLift p) => ClosedTerm p -> PLifted p
plift prog = case plift' prog of
  Right x -> x
  Left e -> error $ "plift failed: " <> show e

-- TODO: Add haddock
newtype DerivePConstantDirect (h :: Type) (p :: PType) = DerivePConstantDirect h

instance
  (PLift p, PLC.DefaultUni `PLC.Includes` h) =>
  PConstant (DerivePConstantDirect h p)
  where
  type PConstantRepr (DerivePConstantDirect h p) = h
  type PConstanted (DerivePConstantDirect h p) = p
  pconstantToRepr = coerce
  pconstantFromRepr = Just . coerce

-- TODO: Add haddock
newtype DerivePConstantViaNewtype (h :: Type) (p :: PType) (p' :: PType) = DerivePConstantViaNewtype h

instance (PLift p, PLift p', Coercible h (PLifted p')) => PConstant (DerivePConstantViaNewtype h p p') where
  type PConstantRepr (DerivePConstantViaNewtype h p p') = PConstantRepr (PLifted p')
  type PConstanted (DerivePConstantViaNewtype h p p') = p
  pconstantToRepr x = pconstantToRepr @(PLifted p') $ coerce x
  pconstantFromRepr x = coerce $ pconstantFromRepr @(PLifted p') x
