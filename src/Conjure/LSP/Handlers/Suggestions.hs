module Conjure.LSP.Handlers.Suggestions where

import Conjure.LSP.Util (ProcessedFile (ProcessedFile), regionToRange, withProcessedDoc,getNextTokenStart,sourcePosToPosition, positionToSourcePos, sendInfoMessage)
import Conjure.Language (Type (..))
import Conjure.Language.AST.Reformer
import Conjure.Language.Type (IntTag (..))
import Conjure.Language.Lexer
import Conjure.Language.Lexemes
import Conjure.Language.Validator --(Class (..), Kind (..), RegionInfo (..), ValidatorState (regionInfo), RegionType (..), StructuralType (..),symbolTable)
import Conjure.Prelude
import Control.Lens
import Data.Text (intercalate,pack)
import Language.LSP.Server (Handlers, LspM, requestHandler)
import Language.LSP.Types (SymbolKind(..),SMethod(STextDocumentCompletion),type  (|?) (..), CompletionItem (..), CompletionItemKind (..), Position(..))
import qualified Language.LSP.Types as T 
import Language.LSP.Types.Lens (HasParams (..), HasTextDocument (textDocument), HasPosition (position), HasCompletionItemKind (completionItemKind))
import Conjure.Language.Pretty (prettyT)
import qualified Data.Map.Strict as Map
import Conjure.Language.Validator (ErrorType(TokenError), DiagnosticRegion (drSourcePos))
import Conjure.Language.AST.Syntax (LToken(MissingToken))
import Conjure.Language.AST.Reformer (HLTree (HLNone), TreeItemLinks (TIList),ListItemClasses(..))
import Text.Megaparsec (SourcePos)

suggestionHandler :: Handlers (LspM ())
suggestionHandler = requestHandler STextDocumentCompletion $ \req res -> do
    let ps = req ^. params . textDocument
    let context = req ^. params . position
    withProcessedDoc ps $ \(ProcessedFile _ diags (regionInfo -> ri) pt) -> do
        let symbols = Map.toList $ rTable $ head  ri
        let nextTStart = getNextTokenStart context pt
        let innermostSymbolTable = symbols
        let errors = [(r,d) | (ValidatorDiagnostic r (Error (TokenError d))) <- diags ] 
        let contextTokens = take 1 [ lexeme w | (r,MissingToken w) <- errors,isInRange nextTStart r] 
        let missingTokenBasedHint = case contextTokens of 
                [l] -> makeMissingTokenHint l
                _ -> makeSuggestionsFromSymbolTable symbols
                where 
                    makeMissingTokenHint (L_Missing s) = case s of
                        MissingExpression -> makeExpressionSuggestions innermostSymbolTable
                        MissingDomain -> makeDomainSuggestions innermostSymbolTable
                        MissingUnknown -> []

                    makeMissingTokenHint LMissingIdentifier = freeIdentifierSuggestion innermostSymbolTable
                    makeMissingTokenHint l = [defaultCompletion $ lexemeText l]
        sendInfoMessage $ pack . show $ context
        let tlSymbol = getLowestLevelTaggedRegion (positionToSourcePos context) $ makeTree pt
        let tlSymbolSuggestion = case tlSymbol of 
                Just (TIDomain _) -> makeDomainSuggestions innermostSymbolTable
                Just (TIExpression _) -> makeExpressionSuggestions innermostSymbolTable
                Just (TIList t) -> makeTagSuggestions innermostSymbolTable t
                q -> [defaultCompletion $ pack . show $ q] 
        res $ Right $ InL . T.List $ tlSymbolSuggestion ++ missingTokenBasedHint

isInRange :: T.Position -> DiagnosticRegion -> Bool
isInRange p reg = sourcePosToPosition (drSourcePos reg) == p

prettyNodeType :: TreeItemLinks -> Text
prettyNodeType (TIExpression _) = "Expression"
prettyNodeType (TIDomain _) = "Domain"
prettyNodeType TIGeneral = "General"
prettyNodeType (TIList t) = pack  ("[ " ++ (show  t) ++ "]")

makeSuggestionsFromSymbolTable :: [(Text,SymbolTableValue)] -> [CompletionItem]
makeSuggestionsFromSymbolTable = map symbolToHint



makeDomainSuggestions :: [(Text,SymbolTableValue)] -> [CompletionItem]
makeDomainSuggestions table = stDomains ++ newDomainPlaceholders
    where stDomains = map symbolToHint $ [x | x@(_,(_,_,Kind DomainType t)) <- table, typesUnifyS [t,TypeAny]]
          newDomainPlaceholders = uncurry snippetCompletion <$> [
            ("int","int"),
            ("int","bool"),
            ("matrix","matrix indexed by ${1:[index_domains]} of ${2:type}"),
            ("set","set of $1"),
            ("mset","mset of $1")
            ]
makeExpressionSuggestions :: [(Text,SymbolTableValue)] -> [CompletionItem]
makeExpressionSuggestions table = stExprs ++ newExpressionPlaceholders
    where stExprs = map symbolToHint $ [x | x@(_,(_,_,Kind ValueType{} t)) <- table,typesUnifyS [t,TypeAny]]
          newExpressionPlaceholders = []
makeTagSuggestions :: [(Text,SymbolTableValue)] -> ListItemClasses -> [CompletionItem]
makeTagSuggestions table tag = case tag of
    ICAttribute -> defaultCompletion <$> ["size"]
    ICExpression -> makeExpressionSuggestions table
    ICDomain -> makeDomainSuggestions table
    ICRange -> uncurry snippetCompletion <$> [("openL","..$1"),("closed","$1..$2"),("openR","$1..")]
    ICIdentifier -> freeIdentifierSuggestion table
    ICStatement -> topLevelSuggestions


symbolToHint :: (Text,SymbolTableValue) -> CompletionItem
symbolToHint (name,(_,_,k)) = let
    typeName = prettyT k
    in (defaultCompletion name){_detail = Just typeName ,_kind=pure $ getCIKind k}

getCIKind :: Kind -> CompletionItemKind
getCIKind (Kind DomainType _) = CiClass
getCIKind (Kind ValueType{} t) = case t of
    TypeAny -> CiVariable
    TypeBool -> CiVariable
    TypeInt _ -> CiVariable
    TypeEnum _ -> CiEnum
    TypeUnnamed _ -> CiVariable
    TypeTuple _ -> CiVariable
    TypeRecord _ -> CiVariable
    TypeRecordMember _ _ -> CiEnumMember
    TypeVariant _ -> CiVariable
    TypeVariantMember _ _ -> CiEnumMember
    TypeList _ -> CiVariable
    TypeMatrix _ _ -> CiVariable
    TypeSet _ -> CiVariable
    TypeMSet _ -> CiVariable
    TypeFunction _ _ -> CiVariable
    TypeSequence _ -> CiVariable
    TypeRelation _ -> CiVariable
    TypePartition _ -> CiVariable

snippetCompletion :: Text -> Text -> CompletionItem
snippetCompletion label snippet = (defaultCompletion label){_kind=pure CiSnippet,_insertText=pure snippet,_insertTextFormat=pure T.Snippet}

defaultCompletion :: Text -> CompletionItem
defaultCompletion n = CompletionItem
    n
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing

missingToSuggestion :: [CompletionItem]
missingToSuggestion = []

keywordCompletions :: [CompletionItem]
keywordCompletions = []

getLowestLevelTaggedRegion :: SourcePos -> HLTree ->  Maybe TreeItemLinks
getLowestLevelTaggedRegion p tr = 
    let regs = filterContaining p tr
    in case [t | HLTagged t _ <- regs, t /= TIGeneral] of
        [] -> Nothing
        (ins) -> Just $ last ins

topLevelSuggestions :: [CompletionItem]
topLevelSuggestions = defaultCompletion <$> [
    "find $1 : $2",
    "such that $0",
    "given $1 : $2"
    ]

freeIdentifierSuggestion :: a -> [CompletionItem]
freeIdentifierSuggestion _ = [defaultCompletion "identifier"]