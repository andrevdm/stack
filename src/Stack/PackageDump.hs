{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveDataTypeable #-}
module Stack.PackageDump
    ( Line
    , eachSection
    , eachPair
    , DumpPackage (..)
    , conduitDumpPackage
    , ghcPkgDump
    , ghcPkgDescribe
    , newInstalledCache
    , loadInstalledCache
    , saveInstalledCache
    , addProfiling
    , addHaddock
    , addSymbols
    , sinkMatching
    , pruneDeps
    ) where

import           Stack.Prelude
import           Data.Attoparsec.Args
import           Data.Attoparsec.Text as P
import           Data.Conduit
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Text as CT
import           Data.List (isPrefixOf)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified RIO.Text as T
import qualified Distribution.License as C
import           Distribution.ModuleName (ModuleName)
import qualified Distribution.System as OS
import qualified Distribution.Text as C
import           Path.Extra (toFilePathNoTrailingSep)
import           Stack.GhcPkg
import           Stack.StoreTH
import           Stack.Types.Compiler
import           Stack.Types.GhcPkgId
import           Stack.Types.PackageDump
import           System.Directory (getDirectoryContents, doesFileExist)
import           System.Process (readProcess) -- FIXME confirm that this is correct
import           RIO.Process hiding (readProcess)

-- | Call ghc-pkg dump with appropriate flags and stream to the given @Sink@, for a single database
ghcPkgDump
    :: (HasProcessContext env, HasLogFunc env)
    => WhichCompiler
    -> [Path Abs Dir] -- ^ if empty, use global
    -> ConduitM Text Void (RIO env) a
    -> RIO env a
ghcPkgDump = ghcPkgCmdArgs ["dump"]

-- | Call ghc-pkg describe with appropriate flags and stream to the given @Sink@, for a single database
ghcPkgDescribe
    :: (HasProcessContext env, HasLogFunc env)
    => PackageName
    -> WhichCompiler
    -> [Path Abs Dir] -- ^ if empty, use global
    -> ConduitM Text Void (RIO env) a
    -> RIO env a
ghcPkgDescribe pkgName' = ghcPkgCmdArgs ["describe", "--simple-output", packageNameString pkgName']

-- | Call ghc-pkg and stream to the given @Sink@, for a single database
ghcPkgCmdArgs
    :: (HasProcessContext env, HasLogFunc env)
    => [String]
    -> WhichCompiler
    -> [Path Abs Dir] -- ^ if empty, use global
    -> ConduitM Text Void (RIO env) a
    -> RIO env a
ghcPkgCmdArgs cmd wc mpkgDbs sink = do
    case reverse mpkgDbs of
        (pkgDb:_) -> createDatabase wc pkgDb -- TODO maybe use some retry logic instead?
        _ -> return ()
    sinkProcessStdout (ghcPkgExeName wc) args sink'
  where
    args = concat
        [ case mpkgDbs of
              [] -> ["--global", "--no-user-package-db"]
              _ -> ["--user", "--no-user-package-db"] ++
                  concatMap (\pkgDb -> ["--package-db", toFilePathNoTrailingSep pkgDb]) mpkgDbs
        , cmd
        , ["--expand-pkgroot"]
        ]
    sink' = CT.decodeUtf8 .| sink

-- | Create a new, empty @InstalledCache@
newInstalledCache :: MonadIO m => m InstalledCache
newInstalledCache = liftIO $ InstalledCache <$> newIORef (InstalledCacheInner Map.empty)

-- | Load a @InstalledCache@ from disk, swallowing any errors and returning an
-- empty cache.
loadInstalledCache :: HasLogFunc env => Path Abs File -> RIO env InstalledCache
loadInstalledCache path = do
    m <- decodeOrLoadInstalledCache path (return $ InstalledCacheInner Map.empty)
    liftIO $ InstalledCache <$> newIORef m

-- | Save a @InstalledCache@ to disk
saveInstalledCache :: HasLogFunc env => Path Abs File -> InstalledCache -> RIO env ()
saveInstalledCache path (InstalledCache ref) =
    readIORef ref >>= encodeInstalledCache path

-- | Prune a list of possible packages down to those whose dependencies are met.
--
-- * id uniquely identifies an item
--
-- * There can be multiple items per name
pruneDeps
    :: (Ord name, Ord id)
    => (id -> name) -- ^ extract the name from an id
    -> (item -> id) -- ^ the id of an item
    -> (item -> [id]) -- ^ get the dependencies of an item
    -> (item -> item -> item) -- ^ choose the desired of two possible items
    -> [item] -- ^ input items
    -> Map name item
pruneDeps getName getId getDepends chooseBest =
      Map.fromList
    . fmap (getName . getId &&& id)
    . loop Set.empty Set.empty []
  where
    loop foundIds usedNames foundItems dps =
        case partitionEithers $ map depsMet dps of
            ([], _) -> foundItems
            (s', dps') ->
                let foundIds' = Map.fromListWith chooseBest s'
                    foundIds'' = Set.fromList $ map getId $ Map.elems foundIds'
                    usedNames' = Map.keysSet foundIds'
                    foundItems' = Map.elems foundIds'
                 in loop
                        (Set.union foundIds foundIds'')
                        (Set.union usedNames usedNames')
                        (foundItems ++ foundItems')
                        (catMaybes dps')
      where
        depsMet dp
            | name `Set.member` usedNames = Right Nothing
            | all (`Set.member` foundIds) (getDepends dp) = Left (name, dp)
            | otherwise = Right $ Just dp
          where
            id' = getId dp
            name = getName id'

-- | Find the package IDs matching the given constraints with all dependencies installed.
-- Packages not mentioned in the provided @Map@ are allowed to be present too.
sinkMatching :: Monad m
             => Bool -- ^ require profiling?
             -> Bool -- ^ require haddock?
             -> Bool -- ^ require debugging symbols?
             -> Map PackageName Version -- ^ allowed versions
             -> ConduitM (DumpPackage Bool Bool Bool) o
                         m
                         (Map PackageName (DumpPackage Bool Bool Bool))
sinkMatching reqProfiling reqHaddock reqSymbols allowed =
      Map.fromList
    . map (pkgName . dpPackageIdent &&& id)
    . Map.elems
    . pruneDeps
        id
        dpGhcPkgId
        dpDepends
        const -- Could consider a better comparison in the future
    <$> (CL.filter predicate .| CL.consume)
  where
    predicate dp =
      isAllowed (dpPackageIdent dp) &&
      (not reqProfiling || dpProfiling dp) &&
      (not reqHaddock || dpHaddock dp) &&
      (not reqSymbols || dpSymbols dp)

    isAllowed (PackageIdentifier name version) =
        case Map.lookup name allowed of
            Just version' | version /= version' -> False
            _ -> True

-- | Add profiling information to the stream of @DumpPackage@s
addProfiling :: MonadIO m
             => InstalledCache
             -> ConduitM (DumpPackage a b c) (DumpPackage Bool b c) m ()
addProfiling (InstalledCache ref) =
    CL.mapM go
  where
    go dp = liftIO $ do
        InstalledCacheInner m <- readIORef ref
        let gid = dpGhcPkgId dp
        p <- case Map.lookup gid m of
            Just installed -> return (installedCacheProfiling installed)
            Nothing | null (dpLibraries dp) -> return True
            Nothing -> do
                let loop [] = return False
                    loop (dir:dirs) = do
                        econtents <- tryIO $ getDirectoryContents dir
                        let contents = either (const []) id econtents
                        if or [isProfiling content lib
                              | content <- contents
                              , lib <- dpLibraries dp
                              ] && not (null contents)
                            then return True
                            else loop dirs
                loop $ dpLibDirs dp
        return dp { dpProfiling = p }

isProfiling :: FilePath -- ^ entry in directory
            -> Text -- ^ name of library
            -> Bool
isProfiling content lib =
    prefix `T.isPrefixOf` T.pack content
  where
    prefix = T.concat ["lib", lib, "_p"]

-- | Add haddock information to the stream of @DumpPackage@s
addHaddock :: MonadIO m
           => InstalledCache
           -> ConduitM (DumpPackage a b c) (DumpPackage a Bool c) m ()
addHaddock (InstalledCache ref) =
    CL.mapM go
  where
    go dp = liftIO $ do
        InstalledCacheInner m <- readIORef ref
        let gid = dpGhcPkgId dp
        h <- case Map.lookup gid m of
            Just installed -> return (installedCacheHaddock installed)
            Nothing | not (dpHasExposedModules dp) -> return True
            Nothing -> do
                let loop [] = return False
                    loop (ifc:ifcs) = do
                        exists <- doesFileExist ifc
                        if exists
                            then return True
                            else loop ifcs
                loop $ dpHaddockInterfaces dp
        return dp { dpHaddock = h }

-- | Add debugging symbol information to the stream of @DumpPackage@s
addSymbols :: MonadIO m
           => InstalledCache
           -> ConduitM (DumpPackage a b c) (DumpPackage a b Bool) m ()
addSymbols (InstalledCache ref) =
    CL.mapM go
  where
    go dp = do
        InstalledCacheInner m <- liftIO $ readIORef ref
        let gid = dpGhcPkgId dp
        s <- case Map.lookup gid m of
            Just installed -> return (installedCacheSymbols installed)
            Nothing | null (dpLibraries dp) -> return True
            Nothing ->
              case dpLibraries dp of
                [] -> return True
                lib:_ ->
                  liftM or . mapM (\dir -> liftIO $ hasDebuggingSymbols dir (T.unpack lib)) $ dpLibDirs dp
        return dp { dpSymbols = s }

hasDebuggingSymbols :: FilePath -- ^ library directory
                    -> String   -- ^ name of library
                    -> IO Bool
hasDebuggingSymbols dir lib = do
    let path = concat [dir, "/lib", lib, ".a"]
    exists <- doesFileExist path
    if not exists then return False
    else case OS.buildOS of
        OS.OSX     -> liftM (any (isPrefixOf "0x") . lines) $
            readProcess "dwarfdump" [path] ""
        OS.Linux   -> liftM (any (isPrefixOf "Contents") . lines) $
            readProcess "readelf" ["--debug-dump=info", "--dwarf-depth=1", path] ""
        OS.FreeBSD -> liftM (any (isPrefixOf "Contents") . lines) $
            readProcess "readelf" ["--debug-dump=info", "--dwarf-depth=1", path] ""
        OS.Windows -> return False -- No support, so it can't be there.
        _          -> return False


-- | Dump information for a single package
data DumpPackage profiling haddock symbols = DumpPackage
    { dpGhcPkgId :: !GhcPkgId
    , dpPackageIdent :: !PackageIdentifier
    , dpParentLibIdent :: !(Maybe PackageIdentifier)
    , dpLicense :: !(Maybe C.License)
    , dpLibDirs :: ![FilePath]
    , dpLibraries :: ![Text]
    , dpHasExposedModules :: !Bool
    , dpExposedModules :: !(Set ModuleName)
    , dpDepends :: ![GhcPkgId]
    , dpHaddockInterfaces :: ![FilePath]
    , dpHaddockHtml :: !(Maybe FilePath)
    , dpProfiling :: !profiling
    , dpHaddock :: !haddock
    , dpSymbols :: !symbols
    , dpIsExposed :: !Bool
    }
    deriving (Show, Eq)

data PackageDumpException
    = MissingSingleField Text (Map Text [Line])
    | Couldn'tParseField Text [Line]
    deriving Typeable
instance Exception PackageDumpException
instance Show PackageDumpException where
    show (MissingSingleField name values) = unlines $
      return (concat
        [ "Expected single value for field name "
        , show name
        , " when parsing ghc-pkg dump output:"
        ]) ++ map (\(k, v) -> "    " ++ show (k, v)) (Map.toList values)
    show (Couldn'tParseField name ls) =
        "Couldn't parse the field " ++ show name ++ " from lines: " ++ show ls

-- | Convert a stream of bytes into a stream of @DumpPackage@s
conduitDumpPackage :: MonadThrow m
                   => ConduitM Text (DumpPackage () () ()) m ()
conduitDumpPackage = (.| CL.catMaybes) $ eachSection $ do
    pairs <- eachPair (\k -> (k, ) <$> CL.consume) .| CL.consume
    let m = Map.fromList pairs
    let parseS k =
            case Map.lookup k m of
                Just [v] -> return v
                _ -> throwM $ MissingSingleField k m
        -- Can't fail: if not found, same as an empty list. See:
        -- https://github.com/fpco/stack/issues/182
        parseM k = Map.findWithDefault [] k m

        parseDepend :: MonadThrow m => Text -> m (Maybe GhcPkgId)
        parseDepend "builtin_rts" = return Nothing
        parseDepend bs =
            liftM Just $ parseGhcPkgId bs'
          where
            (bs', _builtinRts) =
                case stripSuffixText " builtin_rts" bs of
                    Nothing ->
                        case stripPrefixText "builtin_rts " bs of
                            Nothing -> (bs, False)
                            Just x -> (x, True)
                    Just x -> (x, True)
    case Map.lookup "id" m of
        Just ["builtin_rts"] -> return Nothing
        _ -> do
            name <- parseS "name" >>= parsePackageNameThrowing . T.unpack
            version <- parseS "version" >>= parseVersionThrowing . T.unpack
            ghcPkgId <- parseS "id" >>= parseGhcPkgId

            -- if a package has no modules, these won't exist
            let libDirKey = "library-dirs"
                libraries = parseM "hs-libraries"
                exposedModules = parseM "exposed-modules"
                exposed = parseM "exposed"
                license =
                    case parseM "license" of
                        [licenseText] -> C.simpleParse (T.unpack licenseText)
                        _ -> Nothing
            depends <- mapMaybeM parseDepend $ concatMap T.words $ parseM "depends"

            -- Handle sublibs by recording the name of the parent library
            -- If name of parent library is missing, this is not a sublib.
            let mkParentLib n = PackageIdentifier n version
                parentLib = mkParentLib <$> (parseS "package-name" >>=
                                             parsePackageNameThrowing . T.unpack)

            let parseQuoted key =
                    case mapM (P.parseOnly (argsParser NoEscaping)) val of
                        Left{} -> throwM (Couldn'tParseField key val)
                        Right dirs -> return (concat dirs)
                  where
                    val = parseM key
            libDirPaths <- parseQuoted libDirKey
            haddockInterfaces <- parseQuoted "haddock-interfaces"
            haddockHtml <- parseQuoted "haddock-html"

            return $ Just DumpPackage
                { dpGhcPkgId = ghcPkgId
                , dpPackageIdent = PackageIdentifier name version
                , dpParentLibIdent = parentLib
                , dpLicense = license
                , dpLibDirs = libDirPaths
                , dpLibraries = T.words $ T.unwords libraries
                , dpHasExposedModules = not (null libraries || null exposedModules)

                -- Strip trailing commas from ghc package exposed-modules (looks buggy to me...).
                -- Then try to parse the module names.
                , dpExposedModules =
                      Set.fromList
                    $ mapMaybe (C.simpleParse . T.unpack . T.dropSuffix ",")
                    $ T.words
                    $ T.unwords exposedModules

                , dpDepends = depends
                , dpHaddockInterfaces = haddockInterfaces
                , dpHaddockHtml = listToMaybe haddockHtml
                , dpProfiling = ()
                , dpHaddock = ()
                , dpSymbols = ()
                , dpIsExposed = exposed == ["True"]
                }

stripPrefixText :: Text -> Text -> Maybe Text
stripPrefixText x y
    | x `T.isPrefixOf` y = Just $ T.drop (T.length x) y
    | otherwise = Nothing

stripSuffixText :: Text -> Text -> Maybe Text
stripSuffixText x y
    | x `T.isSuffixOf` y = Just $ T.take (T.length y - T.length x) y
    | otherwise = Nothing

-- | A single line of input, not including line endings
type Line = Text

-- | Apply the given Sink to each section of output, broken by a single line containing ---
eachSection :: Monad m
            => ConduitM Line Void m a
            -> ConduitM Text a m ()
eachSection inner =
    CL.map (T.filter (/= '\r')) .| CT.lines .| start
  where

    peekText = await >>= maybe (return Nothing) (\bs ->
        if T.null bs
            then peekText
            else leftover bs >> return (Just bs))

    start = peekText >>= maybe (return ()) (const go)

    go = do
        x <- toConsumer $ takeWhileC (/= "---") .| inner
        yield x
        CL.drop 1
        start

-- | Grab each key/value pair
eachPair :: Monad m
         => (Text -> ConduitM Line Void m a)
         -> ConduitM Line a m ()
eachPair inner =
    start
  where
    start = await >>= maybe (return ()) start'

    start' bs1 =
        toConsumer (valSrc .| inner key) >>= yield >> start
      where
        (key, bs2) = T.break (== ':') bs1
        (spaces, bs3) = T.span (== ' ') $ T.drop 1 bs2
        indent = T.length key + 1 + T.length spaces

        valSrc
            | T.null bs3 = noIndent
            | otherwise = yield bs3 >> loopIndent indent

    noIndent = do
        mx <- await
        case mx of
            Nothing -> return ()
            Just bs -> do
                let (spaces, val) = T.span (== ' ') bs
                if T.length spaces == 0
                    then leftover val
                    else do
                        yield val
                        loopIndent (T.length spaces)

    loopIndent i =
        loop
      where
        loop = await >>= maybe (return ()) go

        go bs
            | T.length spaces == i && T.all (== ' ') spaces =
                yield val >> loop
            | otherwise = leftover bs
          where
            (spaces, val) = T.splitAt i bs

-- | General purpose utility
takeWhileC :: Monad m => (a -> Bool) -> ConduitM a a m ()
takeWhileC f =
    loop
  where
    loop = await >>= maybe (return ()) go

    go x
        | f x = yield x >> loop
        | otherwise = leftover x
