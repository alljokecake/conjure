module Conjure.Language.IntContainer where

import Conjure.Prelude

class IntContainer a where
    intOut :: MonadFail m => a -> m Int

