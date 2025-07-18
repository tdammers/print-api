{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use mapMaybe" #-}
{-# HLINT ignore "Functor law" #-}

-- |
--  Module      : PrintApi.CLI.Cmd.Dump
--  Copyright   : © Hécate, 2024
--  License     : MIT
--  Maintainer  : hecate@glitchbra.in
--  Visibility  : Public
--
--  The processing of package information
module PrintApi.CLI.Cmd.Dump
  ( run
  , computePackageAPI
  ) where

import Control.Monad.IO.Class
import Data.Function (on, (&))
import Data.List qualified as List
import Data.List.Extra qualified as List
import Data.Maybe
import Data.Maybe qualified as Maybe
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import GHC
  ( Module
  , ModuleInfo
  , getModuleInfo
  , getNamePprCtx
  , lookupName
  , lookupQualifiedModule
  , modInfoExports
  , modInfoIface
  , moduleName
  , parseDynamicFlags
  , runGhc
  , setProgramDynFlags
  )
import GHC.Compat as Compat
import GHC.Core.Class (classMinimalDef)
import GHC.Core.InstEnv (ClsInst, instEnvElts, instanceHead)
import GHC.Data.FastString (fsLit)
import GHC.Driver.Env (hscEPS, hsc_units)
import GHC.Driver.Monad (Ghc, getSession, getSessionDynFlags)
import GHC.Driver.Ppr (showSDocForUser)
import GHC.Hs.Doc (Docs (..), WithHsDocIdentifiers (..))
import GHC.Hs.DocString (HsDocStringChunk (..), docStringChunks)
import GHC.Plugins (ModIface_ (mi_docs), PkgQual (..), tyConClass_maybe)
import GHC.Types.Name (NamedThing (..), nameOccName, stableNameCmp)
import GHC.Types.SrcLoc (Located, noLoc, unLoc)
import GHC.Types.TyThing (TyThing (..), tyThingParent_maybe)
import GHC.Types.TyThing.Ppr (pprTyThing)
import GHC.Unit.External (eps_inst_env)
import GHC.Unit.Info (PackageName (..), UnitInfo, unitExposedModules, unitId)
import GHC.Unit.Module (ModuleName, mkModuleName)
import GHC.Unit.State (lookupPackageName, lookupUnitId)
import GHC.Unit.Types (UnitId(..))
import GHC.Utils.Logger (HasLogger (..))
import GHC.Utils.Outputable
  ( Depth (..)
  , IsDoc (..)
  , IsLine (..)
  , IsOutput (..)
  , Outputable (..)
  , SDoc
  , hang
  , nest
  , withUserStyle
  )
import System.IO qualified as System
import System.OsPath qualified as OsPath
import Prelude hiding ((<>))

import Data.Functor ((<&>))
import PrintApi.IgnoredDeclarations
import PrintApi.CLI.Types (PackageDesc(..))
import System.OsPath (OsPath)

run
  :: FilePath
  -> Maybe OsPath
  -> Bool
  -> [String] -- ^ GHC options
  -> PackageDesc
  -> IO ()
run root mIgnoreList usePublicOnly ghcOptions pdesc = do
  case mIgnoreList of
    Nothing -> do
      rendered <- computePackageAPI usePublicOnly root ghcOptions [] pdesc
      liftIO $ putStrLn rendered
    Just ignoreListPath -> do
      userIgnoredModules <- do
        ignoreListFilePath <- liftIO $ OsPath.decodeFS ignoreListPath
        modules <- lines <$> liftIO (System.readFile ignoreListFilePath)
        pure $ List.map mkModuleName modules
      rendered <- computePackageAPI usePublicOnly root ghcOptions userIgnoredModules pdesc
      liftIO $ putStrLn rendered

getPackageDesc
    :: PackageDesc
    -> Ghc UnitInfo
getPackageDesc pdesc = do
  unit_state <- hsc_units <$> getSession
  unitId <- case pdesc of
    ByPackageName name -> do
        case lookupPackageName unit_state (PackageName $ fsLit name) of
          Just unitId -> pure unitId
          Nothing -> fail "failed to find package"
    ByUnitId uid -> return $ UnitId $ fsLit uid
  case lookupUnitId unit_state unitId of
    Just unitInfo -> pure unitInfo
    Nothing -> fail "unknown package"

packageFlag :: PackageDesc -> String
packageFlag (ByPackageName name) = "-package=" ++ name
packageFlag (ByUnitId uid) = "-unit-id=" ++ uid

computePackageAPI
  :: Bool
  -> FilePath
  -> [String]
  -> [ModuleName]
  -> PackageDesc
  -> IO String
computePackageAPI usePublicOnly root ghcOptions userIgnoredModules pdesc = runGhc (Just root) $ do
  let args :: [Located String] =
        map noLoc $
          [ packageFlag pdesc
          , "-dppr-cols=1000"
          , "-fprint-explicit-runtime-reps"
          , "-fprint-explicit-foralls"
          ] ++ ghcOptions
  dflags <- do
    dflags <- getSessionDynFlags
    logger <- getLogger
    (dflags', _fileish_args, _dynamicFlagWarnings) <-
      GHC.parseDynamicFlags logger dflags args
    pure dflags'

  _ <- setProgramDynFlags dflags
  unitInfo <- getPackageDesc pdesc
  decls_doc <- reportUnitDecls usePublicOnly userIgnoredModules unitInfo
  insts_doc <- reportInstances

  unit_state <- hsc_units <$> getSession
  name_ppr_ctx <- GHC.getNamePprCtx
  pure $ List.trim $ showSDocForUser dflags unit_state name_ppr_ctx (vcat [decls_doc, insts_doc])

reportUnitDecls :: Bool -> [ModuleName] -> UnitInfo -> Ghc SDoc
reportUnitDecls usePublicOnly userIgnoredModules unitInfo = do
  let exposed :: [ModuleName]
      exposed = map fst (unitExposedModules unitInfo)
  vcat <$> mapM (reportModuleDecls usePublicOnly userIgnoredModules $ unitId unitInfo) exposed

reportModuleDecls :: Bool -> [ModuleName] -> UnitId -> ModuleName -> Ghc SDoc
reportModuleDecls usePublicOnly userIgnoredModules unitId moduleName
  | moduleName `elem` (userIgnoredModules ++ ignoredModules) = do
      pure $ vcat [modHeader moduleName, text "-- ignored", text ""]
  | otherwise = do
      modl <- GHC.lookupQualifiedModule (OtherPkg unitId) moduleName
      mb_mod_info <- GHC.getModuleInfo modl
      mod_info <- case mb_mod_info of
        Nothing -> fail "Failed to find module"
        Just mod_info -> pure mod_info
      if usePublicOnly then do
          let mDocs =
                mod_info
                  & modInfoIface
                  & Maybe.fromJust
                  & mi_docs
          case mDocs of
            Nothing -> pure empty
            Just docs -> do
              if isVisible docs
                then extractModuleDeclarations modl mod_info
                else pure empty
      else
        extractModuleDeclarations modl mod_info

extractModuleDeclarations :: Module -> ModuleInfo -> Ghc SDoc
extractModuleDeclarations modl mod_info = do
  name_ppr_ctx <- Compat.mkNamePprCtxForModule modl mod_info
  let names = modInfoExports mod_info
  let sorted_names = List.sortBy (compare `on` nameOccName) names
  things <-
    sorted_names
      & mapM lookupName
      <&> catMaybes
      <&> filter
        ( \e -> case tyThingParent_maybe e of
            Just parent
              | isExported mod_info (getOccName parent) -> False
            _ -> True
        )
  let contents =
        vcat $
          [ pprTyThing ss thing $$ extras
          | let ss = mkShowSub mod_info
          , thing <- things
          , let extras =
                  case thing of
                    ATyCon tycon
                      | Just cls <- tyConClass_maybe tycon ->
                          nest
                            2
                            (text "{-# MINIMAL" <+> ppr (classMinimalDef cls) <+> text "#-}")
                    _ -> empty
          ]
  pure $ withUserStyle name_ppr_ctx AllTheWay $ hang (modHeader (moduleName modl)) 2 contents <> text ""

reportInstances :: Ghc SDoc
reportInstances = do
  hsc_env <- getSession
  eps <- liftIO $ hscEPS hsc_env
  let instances = eps_inst_env eps
  pure $
    vcat $
      [ text ""
      , text ""
      , text "-- Instances:"
      ]
        ++ [ ppr inst
           | inst <- List.sortBy compareInstances (instEnvElts instances)
           , not $ ignoredInstance inst
           ]

compareInstances :: ClsInst -> ClsInst -> Ordering
compareInstances inst1 inst2 =
  mconcat
    [ stableNameCmp (getName cls1) (getName cls2)
    ]
  where
    (_, cls1, _tys1) = instanceHead inst1
    (_, cls2, _tys2) = instanceHead inst2

modHeader :: ModuleName -> SDoc
modHeader moduleName =
  vcat
    [ text ""
    , text "module" <+> ppr moduleName <+> text "where"
    , text ""
    ]

isVisible :: Docs -> Bool
isVisible moduleDocs =
  let mModuleHeader = moduleDocs.docs_mod_hdr
   in case mModuleHeader of
        Nothing -> False
        Just hsDoc ->
          let chunks = unLoc <$> docStringChunks hsDoc.hsDocString
              fields' = fmap (\(HsDocStringChunk bs) -> TE.decodeUtf8 bs) chunks
              fields =
                fields'
                  & filter (not . Text.null)
                  & fmap parseField
                  & Maybe.catMaybes
           in List.elem ("visibility", "public") fields

parseField :: Text -> Maybe (Text, Text)
parseField source =
  let pairs = source & Text.splitOn ":"
   in case pairs of
        (x : y : _) -> Just (transformField x, transformField y)
        _ -> Nothing

transformField :: Text -> Text
transformField = Text.toLower . Text.strip
