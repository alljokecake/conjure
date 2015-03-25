{-# LANGUAGE QuasiQuotes #-}

module Conjure.Representations.Function.Function1DPartial ( function1DPartial ) where

-- conjure
import Conjure.Prelude
import Conjure.Language.Definition
import Conjure.Language.Domain
import Conjure.Language.Pretty
import Conjure.Language.TH
import Conjure.Language.ZeroVal ( zeroVal )
import Conjure.Representations.Internal
import Conjure.Representations.Common
import Conjure.Representations.Function.Function1D ( domainValues )


function1DPartial :: forall m . (MonadFail m, NameGen m) => Representation m
function1DPartial = Representation chck downD structuralCons downC up

    where

        chck :: TypeOf_ReprCheck m
        chck f (DomainFunction _
                    attrs@(FunctionAttr _ PartialityAttr_Partial _)
                    innerDomainFr
                    innerDomainTo) | domainCanIndexMatrix innerDomainFr =
            DomainFunction "Function1DPartial" attrs
                <$> f innerDomainFr
                <*> f innerDomainTo
        chck _ _ = []

        nameFlags  name = mconcat [name, "_", "Function1DPartial_Flags"]
        nameValues name = mconcat [name, "_", "Function1DPartial_Values"]

        downD :: TypeOf_DownD m
        downD (name, DomainFunction "Function1DPartial"
                    (FunctionAttr _ PartialityAttr_Partial _)
                    innerDomainFr
                    innerDomainTo) | domainCanIndexMatrix innerDomainFr = return $ Just
            [ ( nameFlags name
              , DomainMatrix
                  (forgetRepr innerDomainFr)
                  DomainBool
              )
            , ( nameValues name
              , DomainMatrix
                  (forgetRepr innerDomainFr)
                  innerDomainTo
              )
            ]
        downD _ = na "{downD} Function1DPartial"

        structuralCons :: TypeOf_Structural m
        structuralCons f downX1
            (DomainFunction "Function1DPartial"
                (FunctionAttr sizeAttr PartialityAttr_Partial jectivityAttr)
                innerDomainFr
                innerDomainTo) | domainCanIndexMatrix innerDomainFr = do

            let injectiveCons flags values = do
                    (iPat, i) <- quantifiedVar
                    (jPat, j) <- quantifiedVar
                    return $ return $ -- list
                        [essence|
                            and([ &values[&i] != &values[&j]
                                | &iPat : &innerDomainFr
                                , &jPat : &innerDomainFr
                                , &i != &j
                                , &flags[&i]
                                , &flags[&j]
                                ])
                        |]

            let surjectiveCons flags values = do
                    (iPat, i) <- quantifiedVar
                    (jPat, j) <- quantifiedVar
                    return $ return $ -- list
                        [essence|
                            forAll &iPat : &innerDomainTo .
                                exists &jPat : &innerDomainFr .
                                    &flags[&j] /\ &values[&j] = &i
                        |]

            let jectivityCons flags values = case jectivityAttr of
                    JectivityAttr_None       -> return []
                    JectivityAttr_Injective  -> injectiveCons  flags values
                    JectivityAttr_Surjective -> surjectiveCons flags values
                    JectivityAttr_Bijective  -> (++) <$> injectiveCons  flags values
                                                     <*> surjectiveCons flags values

            let cardinality flags = do
                    (iPat, i) <- quantifiedVar
                    return [essence| sum &iPat : &innerDomainFr . toInt(&flags[&i]) |]

            let dontCareInactives flags values = do
                    (iPat, i) <- quantifiedVar
                    return $ return $ -- list
                        [essence|
                            forAll &iPat : &innerDomainFr . &flags[&i] = false ->
                                dontCare(&values[&i])
                        |]

            let innerStructuralCons flags values = do
                    (iPat, i) <- quantifiedVar
                    let activeZone b = [essence| forAll &iPat : &innerDomainFr . &flags[&i] -> &b |]

                    -- preparing structural constraints for the inner guys
                    innerStructuralConsGen <- f innerDomainTo

                    let inLoop = [essence| &values[&i] |]
                    outs <- innerStructuralConsGen inLoop
                    return (map activeZone outs)

            return $ \ func -> do
                refs <- downX1 func
                case refs of
                    [flags,values] ->
                        concat <$> sequence
                            [ jectivityCons     flags values
                            , dontCareInactives flags values
                            , mkSizeCons sizeAttr <$> cardinality flags
                            , innerStructuralCons flags values
                            ]
                    _ -> na "{structuralCons} Function1DPartial"

        structuralCons _ _ _ = na "{structuralCons} Function1DPartial"

        downC :: TypeOf_DownC m
        downC ( name
              , DomainFunction "Function1DPartial"
                    (FunctionAttr _ PartialityAttr_Partial _)
                    innerDomainFr
                    innerDomainTo
              , ConstantAbstract (AbsLitFunction vals)
              ) | domainCanIndexMatrix innerDomainFr = do
            z <- zeroVal innerDomainTo
            froms               <- domainValues innerDomainFr
            (flagsOut, valsOut) <- unzip <$> sequence
                [ val
                | fr <- froms
                , let val = case lookup fr vals of
                                Nothing -> return (ConstantBool False, z)
                                Just v  -> return (ConstantBool True , v)
                ]
            return $ Just
                [ ( nameFlags name
                  , DomainMatrix
                      (forgetRepr innerDomainFr)
                      DomainBool
                  , ConstantAbstract $ AbsLitMatrix
                      (forgetRepr innerDomainFr)
                      flagsOut
                  )
                , ( nameValues name
                  , DomainMatrix
                      (forgetRepr innerDomainFr)
                      innerDomainTo
                  , ConstantAbstract $ AbsLitMatrix
                      (forgetRepr innerDomainFr)
                      valsOut
                  )
                ]
        downC _ = na "{downC} Function1DPartial"

        up :: TypeOf_Up m
        up ctxt (name, domain@(DomainFunction "Function1DPartial"
                                (FunctionAttr _ PartialityAttr_Partial _)
                                innerDomainFr _)) =
            case (lookup (nameFlags name) ctxt, lookup (nameValues name) ctxt) of
                ( Just (ConstantAbstract (AbsLitMatrix _ flagMatrix)) ,
                  Just (ConstantAbstract (AbsLitMatrix _ valuesMatrix)) ) -> do
                    froms          <- domainValues innerDomainFr
                    functionValues <- forM (zip3 flagMatrix froms valuesMatrix) $ \ (flag, from, to) ->
                        case flag of
                            ConstantBool b -> return $ if b then Just (from,to) else Nothing
                            _ -> fail $ vcat [ "Expected a boolean, but got:" <+> pretty flag
                                             , "When working on:" <+> pretty name
                                             , "With domain:" <+> pretty domain
                                             ]
                    return ( name, ConstantAbstract $ AbsLitFunction $ catMaybes functionValues )
                (Nothing, _) -> fail $ vcat $
                    [ "No value for:" <+> pretty (nameFlags name)
                    , "When working on:" <+> pretty name
                    , "With domain:" <+> pretty domain
                    ] ++
                    ("Bindings in context:" : prettyContext ctxt)
                (_, Nothing) -> fail $ vcat $
                    [ "No value for:" <+> pretty (nameValues name)
                    , "When working on:" <+> pretty name
                    , "With domain:" <+> pretty domain
                    ] ++
                    ("Bindings in context:" : prettyContext ctxt)
                _ -> fail $ vcat $
                    [ "Expected matrix literals for:" <+> pretty (nameFlags name)
                                            <+> "and" <+> pretty (nameValues name)
                    , "When working on:" <+> pretty name
                    , "With domain:" <+> pretty domain
                    ] ++
                    ("Bindings in context:" : prettyContext ctxt)
        up _ _ = na "{up} Function1DPartial"
