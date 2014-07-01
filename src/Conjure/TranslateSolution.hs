{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ViewPatterns #-}

module Conjure.TranslateSolution ( translateSingleSolution, translateSolution ) where

-- conjure
import Conjure.UpDown
import Language.E.Imports
import Language.E.Definition
import Language.E.Pretty

-- containers
import Data.Tree ( Tree(..) )

-- safe
-- import Safe ( headNote )


-- | Translating a collection of low level values together with their low level domains to high level domains and values.
--   A tree of representations is taken as an argument. Values in this tree give representations for each level of nesting for the domain.
--   Example: NoRepresentation (x, int, 3) --> (x, int, 3)
--
--            NoRepresentation (x_1, int, 1) (x_2, bool, false) --> (x, (int,bool), (1,false))
--
--            Explicit         (x_Explicit, matrix indexed by [int(1..4)] of int(1..9), [1,3,5,6;int(1..4)]) --> (x,set (size 4) of int(1..9),{1,3,5,6})
--
--            Explicit, Explicit
--                ( x_Explicit_Explicit
--                , matrix indexed by [int(1..4)] of matrix indexed by [int(1..3)] of int(1..9)
--                , [ [1,3,5;int(1..3)]
--                  , [2,3,6;int(1..3)]
--                  , [3,4,5;int(1..3)]
--                  , [3,4,8;int(1..3)]
--                  ; int(1..4)
--                  ]
--                )
--            --> ( x_Explicit
--                , matrix indexed by [int(1..4)] of set (size 3) of int(1..9)
--                , [ {1,3,5}
--                  , {2,3,6}
--                  , {3,4,5}
--                  , {3,4,8}
--                  ; int(1..4)
--                  ]
--                )
--            --> ( x
--                , set (size 4) of set (size 3) of int(1..9)
--                , { {1,3,5}
--                  , {2,3,6}
--                  , {3,4,5}
--                  , {3,4,8}
--                  }
--                )
--
--            Explicit, Occurrence
--                ( x_Explicit_Occurrence
--                , matrix indexed by [int(1..4)] of matrix indexed by [int(1..9)] of bool
--                , [ [1,0,1,0,1,0,0,0,0;int(1..9)]
--                  , [0,1,1,0,0,1,0,0,0;int(1..9)]
--                  , [0,0,1,1,1,0,0,0,0;int(1..9)]
--                  , [0,0,1,1,0,0,0,1,0;int(1..9)]
--                  ; int(1..4)
--                  ]
--                )
--            --> ( x_Explicit
--                , matrix indexed by [int(1..4)] of set (size 3) of int(1..9)
--                , [ {1,3,5}
--                  , {2,3,6}
--                  , {3,4,5}
--                  , {3,4,8}
--                  ; int(1..4)
--                  ]
--                )
--            --> ( x
--                , set (size 4) of set (size 3) of int(1..9)
--                , { {1,3,5}
--                  , {2,3,6}
--                  , {3,4,5}
--                  , {3,4,8}
--                  }
--                )
-- 
translateSingleSolution
    :: MonadError UpDownError m
    => Text
    -> Domain () Constant
    -> Tree Representation
    ->  [(Text, Constant)]
    -> m (Text, Constant)

translateSingleSolution highName highDomain representations lows = do
    structuredNames <- structureLows highName highDomain representations
    let structuredLows = fmap (\ name -> (name, lookup name lows) ) structuredNames
    singleHelper highDomain representations structuredLows


singleHelper
    :: MonadError UpDownError m
    => Domain () Constant
    -> Tree Representation
    -> T (Text, Maybe Constant)
    -> m (Text, Constant)

-- empty matrices, I assume the following should be it. we'll see.
singleHelper (DomainMatrix index _) _ (Group [Single (name, Just (ConstantMatrix _ []))]) = do
    return (name, ConstantMatrix index [])

singleHelper (DomainMatrix index inner) representation structuredLows = do
    let
        getFromGroups :: T (Text, Maybe Constant) -> (Text, [Constant])
        getFromGroups (Single (name, Just (ConstantMatrix _ constants))) = (name, constants)
        getFromGroups (Group [a]) = getFromGroups a
        getFromGroups g = error $ unlines [ "BUG: getFromSingletonGroups"
                                          , show g
                                          ]

    let (name, constants) = getFromGroups structuredLows

    (highName, highConstants) <- liftM unzip $ sequence
        [ singleHelper inner representation (Group [Single (name, Just c)])
        | c <- constants
        ]

    return (head highName, ConstantMatrix index highConstants)

singleHelper highDomain (Node representation []) (Group [Single (lowName, Just lowConstant)]) = do
    (_, _, highNamesGen, _, highConstantGen) <- upDown representation highDomain
    highName <- highNamesGen [lowName]
    highConstant <- highConstantGen [lowConstant]
    return (highName, highConstant)


singleHelper highDomain (Node representation rs) (Group lows) = do
    (lowDomainsGen, _, highNamesGen, _, highConstantGen) <- upDown representation highDomain
    lowDomains <- lowDomainsGen
    (midNames, midConstants) <- liftM unzip $ sequence
        [ singleHelper d r low
        | d <- lowDomains
        | r <- rs
        | low <- lows
        ]
    highName <- highNamesGen midNames
    highConstant <- highConstantGen midConstants
    return (highName, highConstant)

singleHelper highDomain representations structuredLows =
    error $ show $ vcat [ pretty "singleHelper"
                        , pretty highDomain
                        -- , pretty $ drawTree $ fmap show representations
                        , pretty representations
                        , pretty $ show structuredLows
                        ]

-- | A tree data type for a collection of constants.
--   Matches the same structure with the tree of representations these constants collectively represent.
data T a = Single a | Group [T a]
    deriving Functor

instance Show a => Show (T a) where
    show (Single a) = "Single " ++ show a
    show (Group xs) = intercalate "\n" $ ("Group " ++ show l) : map (intercalate "\n" . map ("---- " ++) . lines . show) xs
        where l = length xs

structureLows
    :: MonadError UpDownError m
    => Text
    -> Domain () Constant
    -> Tree Representation
    -> m (T Text)

structureLows highName (DomainMatrix _ inner) representation =
    structureLows highName inner representation

structureLows highName highDomain (Node representation rs) = do
    (lowDomainsGen, lowNamesGen, _, _, _) <- upDown representation highDomain
    let lowNames = [ gen highName | gen <- lowNamesGen ]
    expects <-
        if null rs
            then return $ map Single lowNames
            else do
                lowDomains <- lowDomainsGen
                sequence
                    [ structureLows n d r
                    | n <- lowNames
                    | d <- lowDomains
                    | r <- rs
                    ]
    return (Group expects)

translateSolution
    :: MonadError UpDownError m
    => Spec                         -- ^ Essence
    -> Spec                         -- ^ Essence'
    -> Spec                         -- ^ Essence' Solution
    -> m Spec                       -- ^ Essence Solution
translateSolution = error "translateSolution"

